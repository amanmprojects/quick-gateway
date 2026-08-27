#!/usr/bin/env bash
# Install the `claude-zen` launcher for Claude Code on any machine that can
# reach the quick-gateway (locally, or via: clients/tunnel.sh <vm-host>).
#
# Creates:
#   ~/.claude-profiles/zen/settings.json   self-contained profile settings
#   ~/.local/bin/claude-zen                launcher
#
# The profile is built from scratch — no dependency on an existing
# ~/.claude/settings.json, plugins, MCP servers, or hooks — so it works on a
# fresh laptop with nothing but Claude Code installed.
#
# Why --settings instead of a plain env profile? Current Claude Code merges
# the legacy ~/.claude/settings.json over CLAUDE_CONFIG_DIR-scoped profiles,
# so its ANTHROPIC_* env would silently win. The --settings flag has higher
# precedence than the user scope and reliably overrides it.
set -euo pipefail

PORT="${QUICK_GATEWAY_PORT:-4000}"
PROFILE_DIR="$HOME/.claude-profiles/zen"
BIN="$HOME/.local/bin"

usage() {
    cat <<EOF
Usage: install-claude-zen.sh [options]
Options:
  --force    regenerate settings.json even if it exists
  --help,-h  show this help
Environment:
  QUICK_GATEWAY_PORT  gateway port (default 4000)
EOF
}

FORCE=false
for arg in "$@"; do
    case "$arg" in
        --force) FORCE=true ;;
        --help|-h) usage; exit 0 ;;
        --*) echo "error: unknown option: $arg" >&2; usage >&2; exit 1 ;;
        *) echo "error: unexpected argument: $arg" >&2; usage >&2; exit 1 ;;
    esac
done

command -v python3 >/dev/null 2>&1 || { echo "error: python3 is required" >&2; exit 1; }
mkdir -p "$PROFILE_DIR" "$BIN"

# Warn if claude or BIN not in PATH (launcher will fail at runtime otherwise)
if ! command -v claude >/dev/null 2>&1; then
    echo "warn: claude not found in PATH — install Claude Code first, then re-run" >&2
fi
case ":$PATH:" in
    *":$BIN:"*) ;;
    *) echo "warn: $BIN not in PATH — add 'export PATH=\"\$HOME/.local/bin:\$PATH\"' to your shell rc" >&2 ;;
esac

if [ -f "$PROFILE_DIR/settings.json" ] && [ "$FORCE" = false ]; then
    echo "keeping existing $PROFILE_DIR/settings.json (use --force to regenerate)"
    # Check if port in existing file differs from requested PORT
    if command -v python3 >/dev/null 2>&1; then
        EXISTING_PORT=$(python3 -c "import json; print(json.load(open('$PROFILE_DIR/settings.json')).get('env',{}).get('ANTHROPIC_BASE_URL',''))" 2>/dev/null | grep -oE '[0-9]+' | tail -1 || true)
        if [ -n "${EXISTING_PORT:-}" ] && [ "$EXISTING_PORT" != "$PORT" ]; then
            echo "warn: existing settings.json uses port $EXISTING_PORT but QUICK_GATEWAY_PORT=$PORT (run with --force to update)" >&2
        fi
    fi
else
    python3 - "$PROFILE_DIR/settings.json" "$PORT" <<'PY'
import json
import sys

port = sys.argv[2] if len(sys.argv) > 2 else "4000"
env = {
    "ANTHROPIC_BASE_URL": f"http://127.0.0.1:{port}",
    "ANTHROPIC_AUTH_TOKEN": "quick-gateway-local",   # dummy; gateway is auth-free
    "ANTHROPIC_API_KEY": "",
    "ANTHROPIC_MODEL": "ox-alpha-free[1m]",
    "CLAUDE_CODE_SUBAGENT_MODEL": "ox-alpha-free[1m]",
    "CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY": "1",
    "CLAUDE_CODE_MAX_OUTPUT_TOKENS": "131072",
    # catalog names aren't first-party Anthropic models; without this Claude
    # Code warns "unrecognized model" on every turn
    "CLAUDE_CODE_DISABLE_UNKNOWN_MODEL_WINDOW_ENFORCEMENT": "1",
}
with open(sys.argv[1], "w") as f:
    json.dump({"env": env}, f, indent=2)
    f.write("\n")
PY
    echo "wrote $PROFILE_DIR/settings.json (port $PORT)"
fi

cat > "$BIN/claude-zen" <<'WRAP'
#!/usr/bin/env bash
# Claude Code on OpenCode Zen via quick-gateway. See clients/install-claude-zen.sh.
set -euo pipefail
SETTINGS="$HOME/.claude-profiles/zen/settings.json"
if [ ! -f "$SETTINGS" ]; then
    echo "error: $SETTINGS not found — run clients/install-claude-zen.sh" >&2
    exit 1
fi
if ! command -v claude >/dev/null 2>&1; then
    echo "error: claude not found in PATH — install Claude Code" >&2
    exit 1
fi
exec claude --settings "$SETTINGS" "$@"
WRAP
chmod +x "$BIN/claude-zen"
echo "installed $BIN/claude-zen — launch with: claude-zen --help"
