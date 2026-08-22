# quick-gateway

A small self-hosted [LiteLLM](https://docs.litellm.ai) gateway that lets **any**
OpenAI-Responses client (**codex CLI**) or Anthropic-Messages client
(**Claude Code**) use [OpenCode Zen](https://opencode.ai/docs/zen/)'s
chat-completions models through one local endpoint.

```
codex ──────────────► /v1/responses ─┐
                                     │   quick-gateway    chat completions
Claude Code ────────► /v1/messages ──┼─► (LiteLLM) ─────────► OpenCode Zen
                                     │   127.0.0.1:4000      /zen/go/v1
any OpenAI client ──► /v1/chat/…  ───┘
```

Why: Zen's Go plan serves different models over different wire protocols —
`ox-alpha-free`, GLM/Kimi/DeepSeek/MiMo/HY only speak **chat completions** —
while codex ≥0.149 speaks *only* the Responses API, and Claude Code speaks
*only* the Anthropic Messages API. The gateway translates in both directions,
including tool calls.

## Server setup (fresh VM)

```bash
git clone https://github.com/amanmprojects/quick-gateway && cd quick-gateway
./install.sh            # prompts for OPENCODE_API_KEY (chmod-600), then asks
                        # to install the system service via sudo.
./install.sh --system   # same, without the service-install prompt (for scripts)
curl -s http://127.0.0.1:4000/v1/models | head -c 200   # sanity check
```

Requires nothing but `curl` — Python is provisioned by [uv](https://docs.astral.sh/uv/)
(no distro packages). Idempotent: safe to re-run.

## Codex (on the VM)

The installer drops `~/.codex/quick-gateway.config.toml` — a self-contained
profile overlay (provider block + selection). Your main `config.toml` is never
touched:

```bash
codex --profile quick-gateway
```

## Laptop / remote Claude Code

1. Keep a tunnel alive to the VM:
   ```bash
   ssh -N -L 4000:127.0.0.1:4000 <vm-host>
   ```
2. Install the launcher (needs python3 + jq-less; idempotent):
   ```bash
   ./clients/install-claude-zen.sh
   ```
3. Launch: `claude-zen` — a full Claude Code session on `ox-alpha-free`
   (or any gateway model via `claude-zen --model kimi-k3`). Everything else —
   permissions, plugins, hooks, theme, token limits — is replicated from your
   main settings at install time.

Why a `--settings` wrapper instead of env vars or cpm alone? Current Claude
Code merges the legacy `~/.claude/settings.json` over `CLAUDE_CONFIG_DIR`
profiles and over process env, so its `ANTHROPIC_*` block silently wins and
requests never reach the gateway. `--settings` outranks the user scope and
reliably overrides it (verified). [claude-profile-manager](https://github.com/JakubKontra/claude-profile-manager)
remains handy for managing the profile files themselves.

The auth token is a dummy — the gateway is auth-free because it listens on
loopback only; reach requires being on the VM or through authenticated SSH.


## Models exposed

All Zen chat-completions-class models, under upstream names — see
[`gateway/config.yaml`](gateway/config.yaml): `ox-alpha-free`,
`glm-5{,.1,.2,.3}`, `kimi-k3`, `kimi-k2.{5,6}`, `kimi-k2.7-code`,
`deepseek-v4-{pro,flash,flash-vision-exp}`, `mimo-v2-{pro,omni}`,
`mimo-v2.5{,-pro}`, `hy3{,-preview}`.

Not routed here (already natively compatible elsewhere):
- `gpt-5.6-luna`, `grok-4.5`, `muse-spark-1.2-contributor` — Zen serves these
  over the Responses API directly; point codex straight at Zen for them.
- `minimax-*`, `qwen*` — Zen serves these over an Anthropic-compatible
  `/messages`; Claude Code can use them without any gateway via
  `ANTHROPIC_BASE_URL=https://opencode.ai/zen/go`.

## Troubleshooting

- **`litellm` crashes importing `proxy_server`**: the repo pins
  `fastapi==0.136.3` because litellm 1.97.x imports FastAPI APIs removed in
  newer releases (its own declared floor). If you bump litellm, revisit the pin
  in `install.sh`.
- **Port 4000 busy**: change `--port` in the unit template and the clients'
  base URLs together.
- **Key rotation**: edit `~/.config/quick-gateway/gateway.env`, then
  `sudo systemctl restart quick-gateway`. Clients need no changes.
- **Gateway logs**: `journalctl -u quick-gateway` (system service).

## Layout

```
install.sh                        idempotent installer (uv-native)
gateway/config.yaml               LiteLLM model catalog
gateway/quick-gateway.service.template   systemd unit (__USER__/__HOME__ rendered)
clients/codex-quick-gateway.config.toml  codex profile overlay
clients/install-claude-zen.sh            Claude Code launcher installer
```
