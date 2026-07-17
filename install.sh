#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
CLAUDE_HOME="${CLAUDE_HOME:-$HOME/.claude}"
HS_HOME="${HS_HOME:-$HOME/.hammerspoon}"
DOCK_HOME="${DOCK_HOME:-$HOME/.claude-dock-station}"
SETTINGS="$CLAUDE_HOME/settings.json"
EMIT="$ROOT/hooks/emit.sh"
LUA_ENTRY="$ROOT/hammerspoon/claude-dock-station.lua"

# 1) deps (skipped automatically in CI/test if already present)
command -v jq >/dev/null || brew install jq
command -v lua >/dev/null || brew install lua
[ -d /Applications/Hammerspoon.app ] || brew install --cask hammerspoon

mkdir -p "$CLAUDE_HOME" "$HS_HOME" "$DOCK_HOME/state"

# 2) default config (only if absent)
if [ ! -f "$DOCK_HOME/config.json" ]; then
  cat > "$DOCK_HOME/config.json" <<'JSON'
{
  "hotkey": { "mods": ["cmd","shift"], "key": "space" },
  "shells": { "overlay": true, "panel": false, "menubar": true },
  "panel": { "corner": "topRight", "width": 300, "height": 420, "screen": "main" },
  "thumbnails": true,
  "interval_secs": 1,
  "theme": "auto",
  "host_app": "Code",
  "stale_secs": 900
}
JSON
fi

# 3) merge hooks into settings.json (backup first)
[ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"
cp "$SETTINGS" "$SETTINGS.bak.$(date +%s)"
CMD="bash '$EMIT'"
jq --arg cmd "$CMD" '
  def add($ev):
    .hooks[$ev] = ((.hooks[$ev] // [])
      | map(select(any(.. | strings; contains("emit.sh")) | not))   # drop our old entry
      + [{ "hooks": [ { "type":"command", "command":$cmd, "_tag":"claude-dock-station" } ] }]);
  .hooks = (.hooks // {})
  | add("SessionStart") | add("UserPromptSubmit") | add("PreToolUse") | add("PostToolUse")
  | add("Notification") | add("Stop") | add("SessionEnd")
' "$SETTINGS" > "$SETTINGS.tmp" && mv "$SETTINGS.tmp" "$SETTINGS"

# 4) hammerspoon load line (idempotent, guarded by markers)
INIT="$HS_HOME/init.lua"
touch "$INIT"
if ! grep -q 'CLAUDE-DOCK-STATION' "$INIT"; then
  {
    echo '-- >>> CLAUDE-DOCK-STATION >>>'
    echo "dofile('$LUA_ENTRY')"
    echo '-- <<< CLAUDE-DOCK-STATION <<<'
  } >> "$INIT"
fi

echo "Claude Dock Station instalado. Abra o Hammerspoon e recarregue a config (menu > Reload Config)."
