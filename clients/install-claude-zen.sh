#!/usr/bin/env bash
# Install the `claude-zen` launcher for Claude Code on any machine that can
# reach the quick-gateway (locally, or via: ssh -N -L 4000:127.0.0.1:4000 <vm>).
#
# Creates:
#   ~/.claude-profiles/zen/settings.json   profile settings (gateway env +
#                                          everything copied from your main
#                                          ~/.claude/settings.json)
#   ~/.local/bin/claude-zen                launcher
#
# Why --settings instead of a plain env profile? Current Claude Code merges
# the legacy ~/.claude/settings.json over CLAUDE_CONFIG_DIR-scoped profiles,
# so its ANTHROPIC_* env would silently win. The --settings flag has higher
# precedence than the user scope and reliably overrides it.
set -euo pipefail

PROFILE_DIR="$HOME/.claude-profiles/zen"
BIN="$HOME/.local/bin"

mkdir -p "$PROFILE_DIR" "$BIN"

if [ -f "$PROFILE_DIR/settings.json" ]; then
    echo "keeping existing $PROFILE_DIR/settings.json"
else
    # start from the main settings (permissions, plugins, hooks, theme ...)
    # if present, then swap provider config to the gateway
    cp "$HOME/.claude/settings.json" "$PROFILE_DIR/settings.json" 2>/dev/null || echo '{}' \
        | cat > "$PROFILE_DIR/settings.json"
    python3 - "$PROFILE_DIR/settings.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
env = d.setdefault("env", {})
env.update({
    "ANTHROPIC_BASE_URL": "http://127.0.0.1:4000",
    "ANTHROPIC_AUTH_TOKEN": "quick-gateway-local",   # dummy; gateway is auth-free
    "ANTHROPIC_API_KEY": "",
    "ANTHROPIC_MODEL": "ox-alpha-free[1m]",
    "CLAUDE_CODE_SUBAGENT_MODEL": "ox-alpha-free[1m]",
    "CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY": "1",
    "CLAUDE_CODE_MAX_OUTPUT_TOKENS": "131072",
})
json.dump(d, open(p, "w"), indent=2)
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
