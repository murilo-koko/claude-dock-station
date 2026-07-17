#!/usr/bin/env bash
# Install the Claude Dock Station hooks on a remote SSH host so its Claude Code
# sessions write state that the LOCAL Hammerspoon engine can pull. Only the hooks
# run remotely — no Hammerspoon/lua needed there, just jq.
set -euo pipefail
HOST="${1:?uso: bash install-remote.sh <ssh-host>   (ex: my-vps)}"
ROOT="$(cd "$(dirname "$0")" && pwd)"

echo "Instalando hooks do Claude Dock Station em '$HOST'…"

# 1) copy emit.sh to the remote
ssh "$HOST" 'mkdir -p ~/.claude-dock-station/hooks ~/.claude-dock-station/state'
scp -q "$ROOT/hooks/emit.sh" "$HOST:.claude-dock-station/hooks/emit.sh"
ssh "$HOST" 'chmod +x ~/.claude-dock-station/hooks/emit.sh'

# 2) merge our hooks into the remote ~/.claude/settings.json (backup first, idempotent)
ssh "$HOST" 'bash -s' <<'REMOTE'
set -e
command -v jq >/dev/null || { echo "ERRO: jq ausente no host remoto"; exit 1; }
SETTINGS="$HOME/.claude/settings.json"
mkdir -p "$HOME/.claude"
[ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"
cp "$SETTINGS" "$SETTINGS.bak.$(date +%s)"
CMD="bash '$HOME/.claude-dock-station/hooks/emit.sh'"
jq --arg cmd "$CMD" '
  def add($ev):
    .hooks[$ev] = ((.hooks[$ev] // [])
      | map(select(any(.. | strings; contains("emit.sh")) | not))
      + [{ "hooks": [ { "type":"command", "command":$cmd, "_tag":"claude-dock-station" } ] }]);
  .hooks = (.hooks // {})
  | add("SessionStart") | add("UserPromptSubmit") | add("PreToolUse") | add("PostToolUse")
  | add("Notification") | add("Stop") | add("SessionEnd")
' "$SETTINGS" > "$SETTINGS.tmp" && mv "$SETTINGS.tmp" "$SETTINGS"
echo "  hooks mesclados em $SETTINGS (backup .bak.* criado)"
REMOTE

echo "Pronto em '$HOST'. Sessões já rodando passam a emitir no PRÓXIMO evento"
echo "(mande um prompt em cada, ou aguarde a próxima atividade). O Dock Station local puxa o estado a cada ~3s."
