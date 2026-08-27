# AGENTS.md

Guidance for AI coding agents (Claude Code, codex, ...) working in this repo.

## What this repo is

`quick-gateway` — a LiteLLM-based gateway that lets OpenAI-Responses clients
(codex CLI) and Anthropic-Messages clients (Claude Code) use OpenCode Zen's
chat-completions models through one loopback endpoint. See README.md for the
full picture; `install.sh` is the single entry point for setup.

## Layout

```
install.sh                              idempotent installer (uv-native)
gateway/config.yaml                     LiteLLM model catalog (18 Zen chat-class models, YAML anchors)
gateway/quick-gateway.service.template  systemd unit (__USER__/__HOME__/__PORT__ placeholders, hardened)
clients/codex-quick-gateway.config.toml self-contained codex profile overlay
clients/install-claude-zen.sh           Claude Code launcher installer (--settings wrapper)
clients/tunnel.sh                       laptop one-command SSH tunnel + health check
.github/workflows/lint.yml              CI (shellcheck, yaml, dry-run)
LICENSE                                 MIT
```

## Non-obvious constraints — do not break these

1. **fastapi + litellm pin.** litellm 1.97.x imports FastAPI APIs removed in newer
   releases (`get_flat_dependant`); its own declared floor (`>=0.136.3`) is the
   last good version. `install.sh` pins `litellm[proxy]==1.97.*` and `fastapi==0.136.3`.
   If you bump litellm: re-check whether the pin can move by running
   `python -c "from litellm.proxy import proxy_server"` after install.
2. **Model catalog entries use clean names + flag + anchor.** Each entry must be
   `model: openai/<name>` with `use_chat_completions_api: true` in
   `litellm_params`, merged from `x-zen-defaults: &zen_defaults`. Do NOT use the
   `openai/chat_completions/<model>` id form — its marker only gets stripped on
   `/v1/responses`; Anthropic and plain-chat ingresses forward it verbatim and
   upstream rejects it.
3. **Auth-free loopback is deliberate.** No master_key; binding is
   `127.0.0.1`. Clients carry dummy tokens (`quick-gateway-local`). Don't add
   auth without also designing key distribution to clients.
4. **The codex overlay is self-contained.**
   `clients/codex-quick-gateway.config.toml` carries BOTH the
   `[model_providers.*]` block and the selection keys, so the user's main
   `~/.codex/config.toml` stays untouched. Keep that property.
5. **Claude Code launcher must pass `--settings`.** Current Claude Code merges
   legacy `~/.claude/settings.json` over `CLAUDE_CONFIG_DIR` profiles AND over
   process env — only the `--settings` flag outranks it. Any rewrite of
   `install-claude-zen.sh` must keep `exec claude --settings <profile.json>`.
6. **Secrets stay out of git.** The Zen key lives in
   `~/.config/quick-gateway/gateway.env` (chmod 600), created interactively at
   install time. `.gitignore` excludes `*.env`, `*.pid`, logs.
7. **`use_chat_completions_url_for_anthropic_messages: true` must stay in
   `litellm_settings`.** Without it, litellm 1.97 routes `/v1/messages` for
   `openai/*` models through its Responses-API adapter first (Anthropic →
   Responses → chat completions); that double hop returns `"content": []` on
   non-streaming calls even when the upstream generated tokens. The setting
   switches to the direct Anthropic → chat-completions conversion.
8. **Port is templated.** Default 4000, override via `QUICK_GATEWAY_PORT` env or
   `--port`. The systemd template uses `__PORT__` placeholder; `install.sh` and
   `tunnel.sh`/`install-claude-zen.sh` all respect `QUICK_GATEWAY_PORT`. If you
   change the default, update unit template, client templates, and README together.

## Testing changes

CI runs `bash -n`, `shellcheck`, `yaml.safe_load` + model count, and
`./install.sh --dry-run`. For manual verify after touching gateway config or installer:

```bash
./install.sh --dry-run --api-key dummy12345678   # preview without side effects
./install.sh --system                 # re-render + restart service (needs sudo)
curl -s http://127.0.0.1:4000/v1/models | head -c 200          # catalog lists
# Responses ingress (codex path):
curl -sN http://127.0.0.1:4000/v1/responses -H 'Content-Type: application/json' \
  -d '{"model":"ox-alpha-free","input":[{"role":"user","content":[{"type":"input_text","text":"say ok"}]}],"stream":true}' | head -5
# Messages ingress + tool_use (Claude Code path):
curl -s http://127.0.0.1:4000/v1/messages -H 'Content-Type: application/json' \
  -H 'x-api-key: dummy' -H 'anthropic-version: 2023-06-01' \
  -d '{"model":"ox-alpha-free","max_tokens":64,"tools":[{"name":"shell","description":"run cmd","input_schema":{"type":"object","properties":{"command":{"type":"array","items":{"type":"string"}}}},"required":["command"]}],"messages":[{"role":"user","content":"create /tmp/x containing pong via shell"}]}' | python3 -m json.tool | head -20
# end-to-end client checks:
codex --profile quick-gateway exec "Reply with exactly: ok"
claude-zen -p "Reply with exactly: ok"
# custom port:
QUICK_GATEWAY_PORT=5000 ./install.sh --dry-run --port 5000 --api-key dummy
```

Gateway logs: `journalctl -u quick-gateway -f`. A healthy request shows
`POST /v1/responses` or `POST /v1/messages` with 200. **Zero POSTs while a
client errors means a client-side precedence problem**, not a gateway problem.

## House rules

- Keep the README's topology diagram and troubleshooting section in sync with
  any behavior change.
- Ports: default 4000 via `QUICK_GATEWAY_PORT`/`--port`; template uses `__PORT__`; if you change default, update unit template, both client
  templates, and README together.
- Commit messages: imperative mood, explain *why* when non-obvious.
