#!/usr/bin/env bash
set -euo pipefail
CLAUDE_HOME="${CLAUDE_HOME:-$HOME/.claude}"
HS_HOME="${HS_HOME:-$HOME/.hammerspoon}"
SETTINGS="$CLAUDE_HOME/settings.json"
INIT="$HS_HOME/init.lua"

if [ -f "$SETTINGS" ]; then
  cp "$SETTINGS" "$SETTINGS.bak.$(date +%s)"
  jq '
    if .hooks then .hooks |= with_entries(
      .value |= map(select(any(.. | strings; contains("emit.sh")) | not))
    ) else . end
  ' "$SETTINGS" > "$SETTINGS.tmp" && mv "$SETTINGS.tmp" "$SETTINGS"
fi

if [ -f "$INIT" ]; then
  sed -i '' '/-- >>> CLAUDE-DOCK-STATION >>>/,/-- <<< CLAUDE-DOCK-STATION <<</d' "$INIT"
fi
echo "Claude Dock Station desinstalado (state/config preservados em ~/.claude-dock-station)."
