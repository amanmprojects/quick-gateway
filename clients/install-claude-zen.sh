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

PROFILE_DIR="$HOME/.claude-profiles/zen"
BIN="$HOME/.local/bin"

command -v python3 >/dev/null 2>&1 || { echo "python3 is required"; exit 1; }
mkdir -p "$PROFILE_DIR" "$BIN"

if [ -f "$PROFILE_DIR/settings.json" ]; then
    echo "keeping existing $PROFILE_DIR/settings.json (delete it to regenerate)"
else
    python3 - "$PROFILE_DIR/settings.json" <<'PY'
import json, sys
env = {
    "ANTHROPIC_BASE_URL": "http://127.0.0.1:4000",
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
json.dump({"env": env}, open(sys.argv[1], "w"), indent=2)
PY
    echo "wrote $PROFILE_DIR/settings.json"
fi

cat > "$BIN/claude-zen" <<'WRAP'
#!/usr/bin/env bash
# Claude Code on OpenCode Zen via quick-gateway. See clients/install-claude-zen.sh.
exec claude --settings "$HOME/.claude-profiles/zen/settings.json" "$@"
WRAP
chmod +x "$BIN/claude-zen"
echo "installed $BIN/claude-zen — launch with: claude-zen"
