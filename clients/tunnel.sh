#!/usr/bin/env bash
# One-command laptop connection to a quick-gateway VM.
#
#   tunnel.sh <vm-host>          open the SSH tunnel (idempotent) and verify
#   tunnel.sh <vm-host> --claude also install the claude-zen launcher
#   tunnel.sh --status           just check whether :4000 is reachable
#
# Needs only ssh + curl. The gateway is loopback-only on the VM, so the tunnel
# is what makes it reachable from your laptop (see README).
set -euo pipefail

LOCAL_PORT=4000
REMOTE_TARGET="127.0.0.1:4000"

ok() { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

reachable() { curl -sf -m3 "http://127.0.0.1:${LOCAL_PORT}/v1/models" >/dev/null 2>&1; }

if [ "${1:-}" = "--status" ]; then
    if reachable; then ok "gateway reachable on 127.0.0.1:${LOCAL_PORT}"; else echo "gateway NOT reachable"; exit 1; fi
    exit 0
fi

VM_HOST="${1:-}"
[ -n "$VM_HOST" ] || die "usage: tunnel.sh <vm-host> [--claude]"

if reachable; then
    ok "tunnel already up - gateway reachable on 127.0.0.1:${LOCAL_PORT}"
else
    # Reuse an existing socket if the server supports it; otherwise plain forward.
    ok "opening tunnel to ${VM_HOST} (${LOCAL_PORT} -> ${REMOTE_TARGET})"
    ssh -o ExitOnForwardFailure=yes -o ServerAliveInterval=30 -o ServerAliveCountMax=3 \
        -fN -L "${LOCAL_PORT}:${REMOTE_TARGET}" "$VM_HOST" \
        || die "ssh tunnel failed (check 'ssh ${VM_HOST}' works and port ${LOCAL_PORT} isn't taken by another process)"
    sleep 1
    reachable || die "tunnel up but gateway not answering on :${LOCAL_PORT} - is quick-gateway running on the VM? (systemctl status quick-gateway)"
    ok "gateway reachable on 127.0.0.1:${LOCAL_PORT}"
fi

case "${2:-}" in
--claude)
    DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    "$DIR/install-claude-zen.sh"
    ;;
esac

echo
echo "Next: claude-zen   (or codex --profile quick-gateway)"
