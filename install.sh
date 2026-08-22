#!/usr/bin/env bash
# quick-gateway installer — idempotent, uv-native, distro-blind.
# Installs LiteLLM under ~/.local/share/quick-gateway, runtime config under
# ~/.config/quick-gateway, wires a codex profile overlay, and (interactive or
# --system) installs the always-on systemd service via sudo.
#
# Secrets: prompts once for OPENCODE_API_KEY, stores it chmod-600 in
# ~/.config/quick-gateway/gateway.env (server-side only; clients need nothing).
#
# Usage: ./install.sh        (safe to re-run)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNTIME_HOME="$HOME/.local/share/quick-gateway"
CONFIG_HOME="$HOME/.config/quick-gateway"
VENV="$RUNTIME_HOME/venv"

log() { printf '\033[1;32m==>\033[0m %s\n' "$*"; }

# --- uv -------------------------------------------------------------------
if command -v uv >/dev/null 2>&1; then
    UV="$(command -v uv)"
elif [ -x "$HOME/.local/bin/uv" ]; then
    UV="$HOME/.local/bin/uv"
else
    log "installing uv"
    curl -LsSf https://astral.sh/uv/install.sh | sh
    UV="$HOME/.local/bin/uv"
fi
log "uv: $($UV --version 2>/dev/null || echo '?')"

# --- python + litellm -----------------------------------------------------
"$UV" python install 3.12
"$UV" venv "$VENV" --python 3.12 --allow-existing
# fastapi is PINNED: litellm 1.97.x still imports fastapi's get_flat_dependant,
# which newer fastapi removed; its own declared floor (>=0.136.3) is the last
# good line. Do not remove the pin without re-testing the import.
log "installing litellm[proxy] (+ fastapi pin)"
"$UV" pip install --python "$VENV/bin/python" 'litellm[proxy]' 'fastapi==0.136.3'
"$VENV/bin/python" -c "from litellm.proxy import proxy_server" \
    || { echo "litellm proxy import failed; fastapi pin may need updating"; exit 1; }

# --- runtime config -------------------------------------------------------
mkdir -p "$CONFIG_HOME"
cp "$REPO_ROOT/gateway/config.yaml" "$CONFIG_HOME/config.yaml"

if [ ! -f "$CONFIG_HOME/gateway.env" ]; then
    printf 'Enter OPENCODE_API_KEY (input hidden): '
    read -rs KEY
    echo
    umask 077
    printf 'OPENCODE_API_KEY=%s\n' "$KEY" > "$CONFIG_HOME/gateway.env"
    log "wrote $CONFIG_HOME/gateway.env (chmod 600)"
else
    log "keeping existing $CONFIG_HOME/gateway.env"
fi

# --- systemd unit (rendered; NOT installed - sudo lines printed below) ----
sed -e "s|__USER__|$USER|" -e "s|__HOME__|$HOME|g" \
    "$REPO_ROOT/gateway/quick-gateway.service.template" \
    > "$CONFIG_HOME/quick-gateway.service"
log "rendered $CONFIG_HOME/quick-gateway.service"

# --- codex overlay --------------------------------------------------------
if [ -d "$HOME/.codex" ]; then
    cp "$REPO_ROOT/clients/codex-quick-gateway.config.toml" "$HOME/.codex/quick-gateway.config.toml"
    log "installed ~/.codex/quick-gateway.config.toml  (use: codex --profile quick-gateway)"
fi

# --- system service (always-on; needs sudo) ---------------------------------
install_system_service() {
    # clear any user-space instance we started earlier - it holds port 4000
    pkill -f "$RUNTIME_HOME/venv/bin/litellm" 2>/dev/null || true
    sleep 1
    sudo cp "$CONFIG_HOME/quick-gateway.service" /etc/systemd/system/
    sudo systemctl daemon-reload
    sudo systemctl enable --now quick-gateway
    sleep 2
    if systemctl is-active --quiet quick-gateway; then
        log "service quick-gateway active ($(curl -s -m5 -o /dev/null -w '%{http_code}' http://127.0.0.1:4000/v1/models) on :4000)"
    else
        echo "WARNING: unit installed but not active - check: journalctl -u quick-gateway"
        return 1
    fi
}

MANUAL_STEPS="To make the gateway permanent, run:
  sudo cp $CONFIG_HOME/quick-gateway.service /etc/systemd/system/
  sudo systemctl daemon-reload && sudo systemctl enable --now quick-gateway"

if [ "${1:-}" = "--system" ]; then
    install_system_service || echo "$MANUAL_STEPS"
elif [ -t 0 ] && [ -t 1 ]; then
    printf 'Install system-level systemd service now (needs sudo)? [Y/n] '
    read -r ANSWER
    case "$ANSWER" in
        n*|N*) echo "$MANUAL_STEPS" ;;
        *)     install_system_service || echo "$MANUAL_STEPS" ;;
    esac
else
    echo "Non-interactive shell detected - skipping service install."
    echo "$MANUAL_STEPS"
fi

cat <<EOF

Laptop / remote Claude Code setup:
  run clients/install-claude-zen.sh there (see README "Laptop / remote Claude Code").

EOF
