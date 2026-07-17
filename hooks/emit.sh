#!/usr/bin/env bash
# Claude Dock Station — fire-and-forget hook emitter.
# Rules: fast, no network, NEVER block a tool, ALWAYS exit 0.
{
  STATE_DIR="${DOCK_STATE_DIR:-$HOME/.claude-dock-station/state}"
  mkdir -p "$STATE_DIR" 2>/dev/null

  INPUT="$(cat 2>/dev/null)"
  # Single jq pass extracts every field at once, @sh-quoted for a safe eval —
  # one jq spawn instead of one per field (gentler on busy/remote hosts).
  eval "$(printf '%s' "$INPUT" | jq -r '@sh "SID=\(.session_id // "") CWD=\(.cwd // "") EVENT=\(.hook_event_name // "") TOOL=\(.tool_name // "") MSG=\(.message // "") TP=\(.transcript_path // "")"' 2>/dev/null)"

  [ -z "${SID:-}" ] && exit 0
  FILE="$STATE_DIR/$SID.json"

  # optional debug trace of EVERY event (enable by touching ~/.claude-dock-station/debug)
  LOGDIR="$(dirname "$STATE_DIR")"
  [ -f "$LOGDIR/debug" ] && printf '%s %-16s %s\n' "$(date +%s)" "${EVENT:-?}" "${SID:0:8}" >> "$LOGDIR/events.log" 2>/dev/null

  if [ "${EVENT:-}" = "SessionEnd" ]; then
    rm -f "$FILE" 2>/dev/null
    exit 0
  fi

  NOW="$(date +%s)"
  case "${EVENT:-}" in
    UserPromptSubmit) STATE="working";   DETAIL="pensando…" ;;
    # AskUserQuestion / ExitPlanMode block on the human, but Claude Code fires no
    # Notification for them — the session just sits at PreToolUse. The tool_name is
    # a definitive "needs you" signal (unlike a stale generic tool, which is only a
    # guess), so escalate immediately. PostToolUse below resets it once answered.
    PreToolUse)
      case "$TOOL" in
        AskUserQuestion) STATE="needs_you"; DETAIL="aguardando resposta" ;;
        ExitPlanMode)    STATE="needs_you"; DETAIL="aguardando aprovação do plano" ;;
        *)               STATE="working";   DETAIL="$TOOL" ;;
      esac ;;
    PostToolUse)      STATE="working";   DETAIL="$TOOL" ;;
    Notification)     STATE="needs_you"; DETAIL="${MSG:-precisa de você}" ;;
    Stop)             STATE="done";      DETAIL="terminou" ;;
    SessionStart)     STATE="idle";      DETAIL="" ;;
    *)                exit 0 ;;
  esac

  # Conversation title (VS Code tab label) — the latest ai-title in the transcript,
  # keyed by session. Bounded tail keeps this cheap even for huge transcripts.
  TITLE=""
  if [ -n "${TP:-}" ] && [ -f "$TP" ]; then
    TITLE="$(tail -c 200000 "$TP" 2>/dev/null | grep '"type":"ai-title"' | tail -1 | jq -r '.aiTitle // empty' 2>/dev/null)"
  fi

  # Workspace root — the project the session belongs to. This hook runs ON the machine that
  # owns the cwd (remote hosts too, via install-remote.sh), so it can just ASK git instead of
  # leaving the engine to guess from path segments: no string heuristic can know that
  # …/dash/supabase/functions is "dash". Local filesystem op, ~7ms.
  #   root="<path>" -> the repo root      root="" -> looked, found none (home dir, cache)
  # When git itself is unavailable the field is OMITTED, so the engine falls back to its path
  # heuristic rather than reading every session as rootless and emptying the launcher.
  HAS_GIT=0; command -v git >/dev/null 2>&1 && HAS_GIT=1
  ROOT=""
  if [ "$HAS_GIT" = 1 ] && [ -n "${CWD:-}" ] && [ -d "$CWD" ]; then
    ROOT="$(git -C "$CWD" rev-parse --show-toplevel 2>/dev/null)"
  fi

  # Unique temp file per process so concurrent hooks for the same session
  # (e.g. parallel PreToolUse calls) never race on the same path. Atomic mv.
  TMPF="$FILE.tmp.$$"
  jq -n --arg sid "$SID" --arg cwd "$CWD" --arg st "$STATE" --arg title "$TITLE" \
        --arg detail "$DETAIL" --argjson now "$NOW" --arg ev "$EVENT" \
        --arg root "$ROOT" --argjson hasgit "$HAS_GIT" --arg home "${HOME:-}" \
        '{session_id:$sid, cwd:$cwd, state:$st, detail:$detail, title:$title, updated_at:$now,
          event:$ev, home:$home}
         + (if $hasgit == 1 then {root:$root} else {} end)' \
        > "$TMPF" 2>/dev/null && mv "$TMPF" "$FILE" 2>/dev/null
} 2>/dev/null
exit 0
