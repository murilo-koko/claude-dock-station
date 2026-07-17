#!/usr/bin/env bash
set -u
FAIL=0
TMP="$(mktemp -d)"
export TEST_HOME="$TMP/home"
export CLAUDE_HOME="$TEST_HOME/.claude"
export HS_HOME="$TEST_HOME/.hammerspoon"
export DOCK_HOME="$TEST_HOME/.claude-dock-station"
mkdir -p "$CLAUDE_HOME" "$HS_HOME"
echo '{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"echo keep-me"}]}]}}' > "$CLAUDE_HOME/settings.json"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

export PATH="$TMP/bin:$PATH"; mkdir -p "$TMP/bin"
printf '#!/usr/bin/env bash\nexit 0\n' > "$TMP/bin/brew"; chmod +x "$TMP/bin/brew"

bash "$ROOT/install.sh"

check() { if eval "$2"; then echo "ok: $1"; else echo "FAIL: $1"; FAIL=1; fi; }
check "backup created"        "ls $CLAUDE_HOME/settings.json.bak.* >/dev/null 2>&1"
check "existing hook kept"    "grep -q keep-me $CLAUDE_HOME/settings.json"
check "our Stop hook added"   "grep -q claude-dock-station $CLAUDE_HOME/settings.json"
check "hs load line added"    "grep -q claude-dock-station $HS_HOME/init.lua"
check "config.json created"   "test -f $DOCK_HOME/config.json"
check "settings valid json"   "jq empty $CLAUDE_HOME/settings.json"

# Idempotency: run again, ensure our block appears exactly once
bash "$ROOT/install.sh"
COUNT="$(grep -c '>>> CLAUDE-DOCK-STATION >>>' $HS_HOME/init.lua)"
check "hs load line once (idempotent)" "[ \"$COUNT\" = \"1\" ]"

# settings.json idempotency: the 6 hook arrays must NOT grow on repeat install.
# Seed has 1 pre-existing PreToolUse keep-me hook; install adds exactly 1 of ours -> 2.
# Stop/SessionStart/etc have only our single entry -> 1. These guard the jq-filter regression.
check "PreToolUse stays at 2 after 2nd install" "[ \"\$(jq '.hooks.PreToolUse|length' $CLAUDE_HOME/settings.json)\" = \"2\" ]"
check "Stop stays at 1 after 2nd install"       "[ \"\$(jq '.hooks.Stop|length' $CLAUDE_HOME/settings.json)\" = \"1\" ]"
check "keep-me still single after 2nd install"  "[ \"\$(jq '[.hooks.PreToolUse[]|.. |strings|select(test(\"keep-me\"))]|length' $CLAUDE_HOME/settings.json)\" = \"1\" ]"

bash "$ROOT/uninstall.sh"
check "uninstall removes hs line" "! grep -q claude-dock-station $HS_HOME/init.lua"
check "uninstall keeps other hook" "grep -q keep-me $CLAUDE_HOME/settings.json"

rm -rf "$TMP"
[ "$FAIL" -eq 0 ] && echo "ALL INSTALL TESTS PASSED" || { echo "INSTALL TESTS FAILED"; exit 1; }
