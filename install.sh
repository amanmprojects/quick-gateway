#!/usr/bin/env bash
# quick-gateway installer — idempotent, uv-native, distro-blind.
# Installs LiteLLM under ~/.local/share/quick-gateway, runtime config under
# ~/.config/quick-gateway, wires a codex profile overlay, and (interactive or
# --system) installs the always-on systemd service via sudo.
#
# Secrets: prompts once for OPENCODE_API_KEY, stores it chmod-600 in
# ~/.config/quick-gateway/gateway.env (server-side only; clients need nothing).
#
# Usage: ./install.sh [options]
#   --system          install systemd service now (needs sudo)
#   --api-key KEY     provide key non-interactively (useful for CI)
#   --port PORT       override gateway port (default 4000, env QUICK_GATEWAY_PORT)
#   --force           re-render configs even if unchanged
#   --dry-run         show what would be done without changing files
#   --uninstall       disable and remove installed artifacts
#   --help            show help

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNTIME_HOME="$HOME/.local/share/quick-gateway"
CONFIG_HOME="$HOME/.config/quick-gateway"
VENV="$RUNTIME_HOME/venv"
PORT="${QUICK_GATEWAY_PORT:-4000}"
LITELLM_PIN="1.97.*"
FASTAPI_PIN="0.136.3"

log() { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarn:\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
    cat <<EOF
Usage: $(basename "$0") [options]
Options:
  --system          install systemd service now (needs sudo, otherwise prompts)
  --api-key KEY     set OPENCODE_API_KEY non-interactively
  --port PORT       gateway port (default: 4000, env QUICK_GATEWAY_PORT)
  --force           overwrite rendered configs even if unchanged
  --dry-run         print actions without writing files or installing
  --uninstall       remove systemd service and installed configs (keeps gateway.env)
  --help, -h        show this help
Environment:
  QUICK_GATEWAY_PORT  same as --port
  OPENCODE_API_KEY    alternative to --api-key
EOF
}

# --- arg parsing ------------------------------------------------------------
API_KEY_ARG=""
API_KEY_SET=false
FORCE=false
DRY_RUN=false
UNINSTALL=false
SYSTEM_FLAG=false

while [ $# -gt 0 ]; do
    case "$1" in
        --system) SYSTEM_FLAG=true; shift ;;
        --api-key)
            [ $# -ge 2 ] || die "--api-key requires an argument"
            API_KEY_ARG="$2"; API_KEY_SET=true; shift 2 ;;
        --port)
            [ $# -ge 2 ] || die "--port requires an argument"
            PORT="$2"; shift 2 ;;
        --force) FORCE=true; shift ;;
        --dry-run) DRY_RUN=true; shift ;;
        --uninstall) UNINSTALL=true; shift ;;
        --help|-h) usage; exit 0 ;;
        --) shift; break ;;
        -*) die "unknown option: $1 (see --help)" ;;
        *) die "unexpected argument: $1 (see --help)" ;;
    esac
done

# Validate port
if ! [[ "$PORT" =~ ^[0-9]+$ ]] || [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; then
    die "invalid --port: $PORT (must be 1-65535)"
fi

if [ "$DRY_RUN" = true ]; then
    log "[dry-run] would use PORT=$PORT, REPO_ROOT=$REPO_ROOT"
fi

# --- uninstall --------------------------------------------------------------
if [ "$UNINSTALL" = true ]; then
    log "uninstall requested"
    if [ "$DRY_RUN" = true ]; then
        echo "[dry-run] would: sudo systemctl disable --now quick-gateway 2>/dev/null || true"
        echo "[dry-run] would: sudo rm -f /etc/systemd/system/quick-gateway.service"
        echo "[dry-run] would: sudo systemctl daemon-reload"
        echo "[dry-run] would: rm -rf $RUNTIME_HOME $CONFIG_HOME/quick-gateway.service $CONFIG_HOME/config.yaml"
        echo "[dry-run] would: keep $CONFIG_HOME/gateway.env (remove manually if needed)"
        exit 0
    fi
    sudo systemctl disable --now quick-gateway 2>/dev/null || true
    sudo rm -f /etc/systemd/system/quick-gateway.service
    sudo systemctl daemon-reload 2>/dev/null || true
    rm -f "$CONFIG_HOME/quick-gateway.service" "$CONFIG_HOME/config.yaml"
    echo "uninstalled service and configs (kept $CONFIG_HOME/gateway.env if it existed)"
    exit 0
fi

# --- baseline tools ---------------------------------------------------------
for tool in curl tar; do
    command -v "$tool" >/dev/null 2>&1 || die "missing required tool: $tool (install it, then re-run)"
done
if ! command -v python3 >/dev/null 2>&1; then
    warn "python3 not found in PATH — uv will provision Python but python3 is needed for templating"
fi

# --- uv -------------------------------------------------------------------
if command -v uv >/dev/null 2>&1; then
    UV="$(command -v uv)"
elif [ -x "$HOME/.local/bin/uv" ]; then
    UV="$HOME/.local/bin/uv"
else
    if [ "$DRY_RUN" = true ]; then
        echo "[dry-run] would: curl -LsSf https://astral.sh/uv/install.sh | sh"
        UV="uv"
    else
        log "installing uv"
        curl -LsSf https://astral.sh/uv/install.sh | sh
        UV="$HOME/.local/bin/uv"
    fi
fi
if [ "$DRY_RUN" = false ]; then
    log "uv: $($UV --version 2>/dev/null || echo '?')"
fi

# --- python + litellm -----------------------------------------------------
if [ "$DRY_RUN" = true ]; then
    echo "[dry-run] would: $UV python install 3.12"
    echo "[dry-run] would: $UV venv $VENV --python 3.12 --allow-existing"
    echo "[dry-run] would: $UV pip install --python $VENV/bin/python 'litellm[proxy]==$LITELLM_PIN' 'fastapi==$FASTAPI_PIN'"
else
    "$UV" python install 3.12
    "$UV" venv "$VENV" --python 3.12 --allow-existing
    # fastapi is PINNED: litellm 1.97.x still imports fastapi's get_flat_dependant,
    # which newer fastapi removed; its own declared floor (>=0.136.3) is the last
    # good line. Do not remove the pin without re-testing the import.
    log "installing litellm[proxy]==$LITELLM_PIN (+ fastapi==$FASTAPI_PIN)"
    "$UV" pip install --python "$VENV/bin/python" "litellm[proxy]==$LITELLM_PIN" "fastapi==$FASTAPI_PIN"
    "$VENV/bin/python" -c "from litellm.proxy import proxy_server" \
        || die "litellm proxy import failed; fastapi pin may need updating"
fi

# --- runtime config -------------------------------------------------------
if [ "$DRY_RUN" = true ]; then
    echo "[dry-run] would: mkdir -p $CONFIG_HOME && cp $REPO_ROOT/gateway/config.yaml $CONFIG_HOME/config.yaml"
else
    mkdir -p "$CONFIG_HOME"
    # Only overwrite if changed or --force, keep backup of previous
    if [ ! -f "$CONFIG_HOME/config.yaml" ] || [ "$FORCE" = true ] || ! cmp -s "$REPO_ROOT/gateway/config.yaml" "$CONFIG_HOME/config.yaml"; then
        if [ -f "$CONFIG_HOME/config.yaml" ]; then
            cp "$CONFIG_HOME/config.yaml" "$CONFIG_HOME/config.yaml.bak"
            warn "backed up existing config to $CONFIG_HOME/config.yaml.bak"
        fi
        cp "$REPO_ROOT/gateway/config.yaml" "$CONFIG_HOME/config.yaml"
        log "installed $CONFIG_HOME/config.yaml"
    else
        log "keeping existing $CONFIG_HOME/config.yaml (unchanged)"
    fi
fi

# Determine API key to store
# Priority for initial creation: --api-key > env > prompt
# For existing file: only --api-key (or --force with env) overwrites; env alone does not
NEEDS_KEY=false
KEY_TO_STORE=""
if [ ! -f "$CONFIG_HOME/gateway.env" ]; then
    NEEDS_KEY=true
    if [ "$API_KEY_SET" = true ]; then
        KEY_TO_STORE="$API_KEY_ARG"
    elif [ -n "${OPENCODE_API_KEY:-}" ]; then
        KEY_TO_STORE="$OPENCODE_API_KEY"
    fi
elif [ "$API_KEY_SET" = true ]; then
    # Existing file but user explicitly wants to update
    NEEDS_KEY=true
    KEY_TO_STORE="$API_KEY_ARG"
fi

if [ "$NEEDS_KEY" = true ]; then
    # Explicit --api-key "" should not fall back to prompt/env
    if [ "$API_KEY_SET" = true ] && [ -z "$KEY_TO_STORE" ]; then
        die "OPENCODE_API_KEY cannot be empty (provided via --api-key)"
    fi
    if [ -z "$KEY_TO_STORE" ]; then
        if [ ! -t 0 ]; then
            die "OPENCODE_API_KEY not set and no --api-key provided (non-interactive shell). Set env or use --api-key."
        fi
        printf 'Enter OPENCODE_API_KEY (input hidden): '
        read -rs KEY_TO_STORE
        echo
    fi
    # Validate key: non-empty, no whitespace/newline/equals, reasonable length
    KEY_TRIMMED="$(printf '%s' "$KEY_TO_STORE" | tr -d '[:space:]')"
    if [ -z "$KEY_TRIMMED" ]; then
        die "OPENCODE_API_KEY cannot be empty"
    fi
    if [ "$KEY_TRIMMED" != "$KEY_TO_STORE" ]; then
        warn "API key contained whitespace — trimmed"
        KEY_TO_STORE="$KEY_TRIMMED"
    fi
    if [[ "$KEY_TO_STORE" == *$'\n'* ]] || [[ "$KEY_TO_STORE" == *"="* ]]; then
        die "OPENCODE_API_KEY must not contain newline or '='"
    fi
    if [ "${#KEY_TO_STORE}" -lt 8 ]; then
        warn "API key looks unusually short (${#KEY_TO_STORE} chars)"
    fi
    if [ "$DRY_RUN" = true ]; then
        echo "[dry-run] would: write $CONFIG_HOME/gateway.env (chmod 600)"
    else
        if [ -f "$CONFIG_HOME/gateway.env" ]; then
            cp "$CONFIG_HOME/gateway.env" "$CONFIG_HOME/gateway.env.bak"
            warn "backed up existing gateway.env to $CONFIG_HOME/gateway.env.bak"
        fi
        # Use subshell so umask does not leak to rest of script
        (umask 077; printf 'OPENCODE_API_KEY=%s\n' "$KEY_TO_STORE" > "$CONFIG_HOME/gateway.env")
        chmod 600 "$CONFIG_HOME/gateway.env"
        log "wrote $CONFIG_HOME/gateway.env (chmod 600)"
    fi
else
    log "keeping existing $CONFIG_HOME/gateway.env"
fi

# --- systemd unit (rendered; NOT installed - sudo lines printed below) ----
if [ "$DRY_RUN" = true ]; then
    echo "[dry-run] would: render $CONFIG_HOME/quick-gateway.service (port $PORT)"
else
    # Use Python for safe placeholder substitution (avoids sed escaping issues with $HOME)
    python3 - "$REPO_ROOT/gateway/quick-gateway.service.template" "$CONFIG_HOME/quick-gateway.service" "${USER:-$(id -un)}" "$HOME" "$PORT" <<'PY'
import sys
src, dst, user, home, port = sys.argv[1:6]
data = open(src).read()
data = data.replace("__USER__", user).replace("__HOME__", home).replace("__PORT__", port)
# Backwards compat: template may still have hardcoded 4000 if __PORT__ not present
if "__PORT__" not in open(src).read() and port != "4000":
    # Fallback: replace literal 4000 port in ExecStart if template not yet templated
    data = data.replace("--port 4000", f"--port {port}")
open(dst, "w").write(data)
PY
    log "rendered $CONFIG_HOME/quick-gateway.service (port $PORT)"
fi

# --- codex overlay --------------------------------------------------------
# Create ~/.codex if absent: a fresh VM shouldn't silently skip the profile.
if [ "$DRY_RUN" = true ]; then
    echo "[dry-run] would: install ~/.codex/quick-gateway.config.toml (port $PORT)"
else
    mkdir -p "$HOME/.codex"
    # Backup if existing and different
    if [ -f "$HOME/.codex/quick-gateway.config.toml" ] && ! cmp -s "$REPO_ROOT/clients/codex-quick-gateway.config.toml" "$HOME/.codex/quick-gateway.config.toml"; then
        # Check if difference is only port
        if ! grep -q "127.0.0.1:${PORT}" "$HOME/.codex/quick-gateway.config.toml" 2>/dev/null; then
            cp "$HOME/.codex/quick-gateway.config.toml" "$HOME/.codex/quick-gateway.config.toml.bak"
            warn "backed up existing codex overlay to ~/.codex/quick-gateway.config.toml.bak"
        fi
    fi
    # Render port if overridden
    if [ "$PORT" != "4000" ]; then
        python3 - "$REPO_ROOT/clients/codex-quick-gateway.config.toml" "$HOME/.codex/quick-gateway.config.toml" "$PORT" <<'PY'
import sys
src, dst, port = sys.argv[1:4]
data = open(src).read()
# Replace literal 4000 with actual port (only in base_url)
data = data.replace("127.0.0.1:4000", f"127.0.0.1:{port}")
open(dst, "w").write(data)
PY
    else
        cp "$REPO_ROOT/clients/codex-quick-gateway.config.toml" "$HOME/.codex/quick-gateway.config.toml"
    fi
    log "installed ~/.codex/quick-gateway.config.toml  (use: codex --profile quick-gateway, port $PORT)"
fi

# --- system service (always-on; needs sudo) ---------------------------------
install_system_service() {
    # Prefer systemctl stop over pkill -f which could match unrelated processes
    if systemctl is-active --quiet quick-gateway 2>/dev/null; then
        sudo systemctl stop quick-gateway 2>/dev/null || true
        sleep 1
    else
        # Fallback: kill stale user-space instance if any
        pkill -f "$RUNTIME_HOME/venv/bin/litellm" 2>/dev/null || true
        sleep 1
    fi
    sudo cp "$CONFIG_HOME/quick-gateway.service" /etc/systemd/system/
    sudo systemctl daemon-reload
    sudo systemctl enable --now quick-gateway
    # Health check loop instead of single sleep
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        if systemctl is-active --quiet quick-gateway 2>/dev/null && curl -sf -m2 "http://127.0.0.1:${PORT}/v1/models" >/dev/null 2>&1; then
            break
        fi
        sleep 0.5
    done
    if systemctl is-active --quiet quick-gateway && curl -sf -m2 "http://127.0.0.1:${PORT}/v1/models" >/dev/null 2>&1; then
        log "service quick-gateway active ($(curl -s -m2 -o /dev/null -w '%{http_code}' "http://127.0.0.1:${PORT}/v1/models") on :${PORT})"
    else
        echo "WARNING: unit installed but not active - check: journalctl -u quick-gateway -f" >&2
        return 1
    fi
}

MANUAL_STEPS="To make the gateway permanent, run:
  sudo cp $CONFIG_HOME/quick-gateway.service /etc/systemd/system/
  sudo systemctl daemon-reload && sudo systemctl enable --now quick-gateway"

if [ "$DRY_RUN" = true ]; then
    echo "[dry-run] would: $MANUAL_STEPS"
elif [ "$SYSTEM_FLAG" = true ]; then
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
  on the laptop:  curl -fsSL https://raw.githubusercontent.com/amanmprojects/quick-gateway/master/clients/tunnel.sh | bash -s -- <vm-host>
  (or run clients/tunnel.sh from a clone; see README "Laptop / remote Claude Code").
  Custom port: QUICK_GATEWAY_PORT=$PORT ./install.sh --port $PORT

EOF
