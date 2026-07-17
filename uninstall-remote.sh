#!/usr/bin/env bash
# Remove the Claude Dock Station hooks from a remote SSH host (keeps state dir).
set -euo pipefail
HOST="${1:?uso: bash uninstall-remote.sh <ssh-host>}"
echo "Removendo hooks do Claude Dock Station em '$HOST'…"
ssh "$HOST" 'bash -s' <<'REMOTE'
set -e
SETTINGS="$HOME/.claude/settings.json"
if [ -f "$SETTINGS" ] && command -v jq >/dev/null; then
  cp "$SETTINGS" "$SETTINGS.bak.$(date +%s)"
  jq 'if .hooks then .hooks |= with_entries(
        .value |= map(select((.. | strings) | contains("emit.sh") | not))
      ) else . end' "$SETTINGS" > "$SETTINGS.tmp" && mv "$SETTINGS.tmp" "$SETTINGS"
  echo "  hooks removidos de $SETTINGS (backup feito)"
fi
REMOTE
echo "Feito. (state dir ~/.claude-dock-station preservado em '$HOST')"
