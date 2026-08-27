#!/usr/bin/env bash
# One-command laptop connection to a quick-gateway VM.
#
#   tunnel.sh <vm-host>          open the SSH tunnel (idempotent) and verify
#   tunnel.sh <vm-host> --claude also install the claude-zen launcher
#   tunnel.sh --status           just check whether :4000 is reachable
#   tunnel.sh --help             show help
#
# Needs only ssh + curl. The gateway is loopback-only on the VM, so the tunnel
# is what makes it reachable from your laptop (see README).
# Port can be overridden via QUICK_GATEWAY_PORT env var (default 4000).
set -euo pipefail

PORT="${QUICK_GATEWAY_PORT:-4000}"
# Keep LOCAL_PORT for backwards compat with callers that source/override it
LOCAL_PORT="${PORT}"
REMOTE_TARGET="127.0.0.1:${PORT}"

ok() { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarn:\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
    cat <<EOF
Usage: tunnel.sh [options] <vm-host>
Options:
  --status   just check whether gateway is reachable on 127.0.0.1:${PORT}
  --claude   also install the claude-zen launcher after tunnel is up
  --help,-h  show this help
Environment:
  QUICK_GATEWAY_PORT  override local/remote port (default 4000)
EOF
}

reachable() { curl -sf -m3 "http://127.0.0.1:${PORT}/v1/models" >/dev/null 2>&1; }

check_prereqs() {
    for tool in curl ssh; do
        command -v "$tool" >/dev/null 2>&1 || die "missing required tool: $tool"
    done
}

# --- arg parsing (order-insensitive for flags) ---
VM_HOST=""
INSTALL_CLAUDE=false
STATUS_ONLY=false

for arg in "$@"; do
    case "$arg" in
        --status) STATUS_ONLY=true ;;
        --claude) INSTALL_CLAUDE=true ;;
        --help|-h) usage; exit 0 ;;
        --*) die "unknown option: $arg (see --help)" ;;
        *)
            if [ -z "$VM_HOST" ]; then
                VM_HOST="$arg"
            else
                die "unexpected argument: $arg (only one <vm-host> allowed)"
            fi
            ;;
    esac
done

check_prereqs

if [ "$STATUS_ONLY" = true ]; then
    if reachable; then ok "gateway reachable on 127.0.0.1:${PORT}"; else echo "gateway NOT reachable on 127.0.0.1:${PORT}" >&2; exit 1; fi
    exit 0
fi

[ -n "$VM_HOST" ] || die "missing <vm-host> (usage: tunnel.sh <vm-host> [--claude]  or  tunnel.sh --status)"

if reachable; then
    ok "tunnel already up - gateway reachable on 127.0.0.1:${PORT}"
else
    # Check if port is bound by something else that isn't the gateway
    if command -v ss >/dev/null 2>&1; then
        if ss -tlnH "sport = :${PORT}" 2>/dev/null | grep -q .; then
            warn "port ${PORT} is bound but gateway not responding - another process may hold the port"
        fi
    elif command -v lsof >/dev/null 2>&1; then
        if lsof -iTCP:"${PORT}" -sTCP:LISTEN -t >/dev/null 2>&1; then
            warn "port ${PORT} is bound but gateway not responding - another process may hold the port"
        fi
    fi

    ok "opening tunnel to ${VM_HOST} (127.0.0.1:${PORT} -> ${REMOTE_TARGET})"
    # Explicitly bind to loopback on both ends to avoid GatewayPorts exposure
    ssh -o ExitOnForwardFailure=yes -o ServerAliveInterval=30 -o ServerAliveCountMax=3 \
        -fN -L "127.0.0.1:${PORT}:${REMOTE_TARGET}" "$VM_HOST" \
        || die "ssh tunnel failed (check 'ssh ${VM_HOST}' works and port ${PORT} isn't taken)"

    # Retry health check (gateway may be slow to respond)
    for _ in 1 2 3 4 5 6 7 8 10; do
        if reachable; then break; fi
        sleep 0.5
    done
    reachable || die "tunnel up but gateway not answering on :${PORT} - is quick-gateway running on the VM? (systemctl status quick-gateway)"
    ok "gateway reachable on 127.0.0.1:${PORT}"
fi

if [ "$INSTALL_CLAUDE" = true ]; then
    DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    "$DIR/install-claude-zen.sh"
fi

echo
echo "Next: claude-zen   (or codex --profile quick-gateway)"
