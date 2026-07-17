#!/usr/bin/env bash
set -u
FAIL=0
TMP="$(mktemp -d)"
export DOCK_STATE_DIR="$TMP/state"
EMIT="$(cd "$(dirname "$0")/.." && pwd)/hooks/emit.sh"

emit() { echo "$1" | bash "$EMIT"; }
field() { jq -r "$2" "$TMP/state/$1.json"; }
check() { if [ "$2" = "$3" ]; then echo "ok: $1"; else echo "FAIL: $1 (got '$2' want '$3')"; FAIL=1; fi; }

emit '{"session_id":"s1","cwd":"/x/webapp-core","hook_event_name":"UserPromptSubmit"}'
check "prompt->working" "$(field s1 .state)" "working"
check "prompt project cwd" "$(field s1 .cwd)" "/x/webapp-core"

emit '{"session_id":"s1","cwd":"/x/webapp-core","hook_event_name":"PreToolUse","tool_name":"Bash"}'
check "pretooluse keeps working" "$(field s1 .state)" "working"
check "pretooluse detail=tool" "$(field s1 .detail)" "Bash"

emit '{"session_id":"s1","cwd":"/x/webapp-core","hook_event_name":"PostToolUse","tool_name":"Bash"}'
check "posttooluse keeps working" "$(field s1 .state)" "working"
check "posttooluse records event" "$(field s1 .event)" "PostToolUse"

emit '{"session_id":"s1","cwd":"/x/webapp-core","hook_event_name":"Stop"}'
check "stop->done" "$(field s1 .state)" "done"

emit '{"session_id":"s1","cwd":"/x/webapp-core","hook_event_name":"Notification","message":"needs permission"}'
check "notification->needs_you" "$(field s1 .state)" "needs_you"

# Blocking-on-user tools: Claude Code fires NO Notification for AskUserQuestion /
# ExitPlanMode — the session just sits at PreToolUse. Escalate them to needs_you
# immediately (the tool_name is a definitive signal), then self-clear on answer.
emit '{"session_id":"s4","cwd":"/x/webapp-core","hook_event_name":"PreToolUse","tool_name":"AskUserQuestion"}'
check "askuserquestion->needs_you" "$(field s4 .state)" "needs_you"
emit '{"session_id":"s5","cwd":"/x/webapp-core","hook_event_name":"PreToolUse","tool_name":"ExitPlanMode"}'
check "exitplanmode->needs_you" "$(field s5 .state)" "needs_you"
emit '{"session_id":"s4","cwd":"/x/webapp-core","hook_event_name":"PostToolUse","tool_name":"AskUserQuestion"}'
check "askuserquestion answered->working" "$(field s4 .state)" "working"

# ai-title extraction from a transcript
TRANSCRIPT="$TMP/t.jsonl"
printf '%s\n' '{"type":"ai-title","aiTitle":"Old title","sessionId":"s2"}' '{"type":"user"}' '{"type":"ai-title","aiTitle":"Latest title","sessionId":"s2"}' > "$TRANSCRIPT"
emit "$(printf '{"session_id":"s2","cwd":"/x/edu","hook_event_name":"PreToolUse","tool_name":"Edit","transcript_path":"%s"}' "$TRANSCRIPT")"
check "title = latest ai-title" "$(field s2 .title)" "Latest title"
emit '{"session_id":"s3","cwd":"/x/y","hook_event_name":"Stop"}'
check "no transcript -> empty title" "$(field s3 .title)" ""

# Workspace root: the hook runs ON the machine that owns the cwd (local AND remote), so it
# resolves the real project root instead of leaving the engine to guess from path segments.
REPO="$TMP/proj-dash"
mkdir -p "$REPO/supabase/functions"
git -C "$REPO" init -q 2>/dev/null
# git reports the PHYSICAL path, and macOS puts mktemp dirs behind the /var -> /private/var
# symlink, so compare against the resolved root rather than the symlinked one.
REPO_REAL="$(cd "$REPO" && pwd -P)"
emit "$(printf '{"session_id":"g1","cwd":"%s/supabase/functions","hook_event_name":"Stop"}' "$REPO")"
check "root = git toplevel of a deep cwd" "$(field g1 .root)" "$REPO_REAL"

# A cwd with no repo reports root="" — the engine reads that as "not a project window"
# (a home dir, Claude's plugin cache) and keeps it out of the recents launcher.
NOREPO="$TMP/not-a-repo"
mkdir -p "$NOREPO"
emit "$(printf '{"session_id":"g2","cwd":"%s","hook_event_name":"Stop"}' "$NOREPO")"
check "no repo -> root empty" "$(field g2 .root)" ""

# A vanished cwd must not hang or error the hook
emit '{"session_id":"g3","cwd":"/nonexistent/gone","hook_event_name":"Stop"}'
check "missing cwd -> root empty" "$(field g3 .root)" ""

# $HOME of the machine that owns the cwd. The engine uses it to spot cwds that are not
# projects (the home dir itself, Claude's own ~/.claude cache) — a check that must work for
# remote sessions too, where the local HOME is meaningless.
check "home = \$HOME of the owning machine" "$(field g3 .home)" "$HOME"

emit '{"session_id":"s1","cwd":"/x/webapp-core","hook_event_name":"SessionEnd"}'
if [ ! -f "$TMP/state/s1.json" ]; then echo "ok: sessionend deletes"; else echo "FAIL: sessionend deletes"; FAIL=1; fi

# Robustness: malformed input must still exit 0
echo 'not json' | bash "$EMIT"; check "malformed exit0" "$?" "0"

rm -rf "$TMP"
[ "$FAIL" -eq 0 ] && echo "ALL EMIT TESTS PASSED" || { echo "EMIT TESTS FAILED"; exit 1; }
