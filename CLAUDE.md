# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository purpose

This repo holds the deployment documentation (not code) for a hybrid AI server: an Ubuntu 24.04 host (192.168.1.199, Xeon E5-2695 v4 / 48GB RAM / NVIDIA P100 16GB) that combines local GGUF models with the Anthropic API, exposed to two client surfaces:

1. Claude Code on Windows → `ccr` (port 3456) → routed per-category to Anthropic or to a local model.
2. Open WebUI in the browser (port 3000) → `llama-swap` (port 8001) → local model.

Edits here are documentation changes. There is no build, lint, or test pipeline. Verify changes by re-reading `README.md` and confirming that commands, ports, paths, and config snippets are internally consistent.

## Architecture (the big picture)

Three services run on the host, each with a fixed role. Get these relationships right before editing anything:

- **`llama-swap`** (port `8001`, systemd unit `llama-swap.service`) — proxy in front of `llama-server`. Reads `~/.config/llama-swap/config.yaml`, which lists every model and its `cmd` line. On each request, llama-swap inspects the `model` field, spawns the matching `llama-server` if needed, proxies the request, and unloads idle models after `ttl` seconds. Models are organized in `groups` so a GPU model and a CPU model can coexist; multiple GPU models share a single slot and swap on demand (~5–10 s cold load).
- **`claude-code-router` / `ccr`** (port `3456`, systemd unit `ccr.service`) — Anthropic-compatible front door for Claude Code clients. Reads `~/.claude-code-router/config.json`. Routes requests by category:
  - `default` → Anthropic Sonnet 4.6
  - `background` → local `qwen2.5-coder-7b` (free, GPU)
  - `think` → Anthropic Opus 4.7
  - `longContext` (>60 K tokens) → Anthropic Opus 4.7
  Loads custom transformer plugins from `~/.claude-code-router/plugins/`.
- **Open WebUI** (port `3000`, Docker `--network host`, `--restart always`) — ChatGPT-style UI. Talks directly to `llama-swap` at `http://localhost:8001/v1`, not through `ccr`. Only `ccr` brokers Anthropic traffic.

### Models registered in llama-swap

| ID | File | Backend | Use |
| --- | --- | --- | --- |
| `qwen2.5-coder-7b` | `Qwen2.5-Coder-7B-Instruct-Q4_K_M.gguf` | GPU (P100) | Default local code model for Claude Code. ~8.6 GB VRAM, ~40 t/s gen, prefill 430 t/s. |
| `qwen2.5-14b-coder` | `Qwen2.5-14B-Instruct-Q4_K_M.gguf` | GPU | Heavier alternative. Slower (~22 t/s gen on P100); kept as opt-in. |
| `gemma-3-4b-familiar` | `google_gemma-3-4b-it-Q5_K_M.gguf` + mmproj-f16 | GPU | Family chat in Open WebUI, with vision (mmproj). |
| `deepseek-r1-distill-7b` | `DeepSeek-R1-Distill-Qwen-7B-Q4_K_M.gguf` | CPU | Reasoning model for non-urgent tasks. Coexists with the GPU model. |

The GPU group (`qwen2.5-coder-7b`, `qwen2.5-14b-coder`, `gemma-3-4b-familiar`) shares one slot. Loading any one unloads the others. `deepseek-r1-distill-7b` is in a separate `cpu` group and is independent.

### Why the P100 needs special handling

Pascal (compute capability 6.0, no Tensor Cores, no DP4A) is slow for prefill on quantized 14B+ models with `--flash-attn` and quantized KV cache. The 7B coder model with `--flash-attn off` and `f16` KV cache hits ~430 t/s prefill, fast enough for Claude Code's ~28 K-token system prompt to be tolerable when prompt-cache reuse works.

Prompt-cache reuse (the difference between a 70 s turn and a 1 s turn) only works when the prompt prefix is byte-stable between turns. Two known sources of churn:

1. **Claude Code's `x-anthropic-billing-header`** (CC ≥ 2.1.36 injects a per-turn `cch=...` token in the first system block). Disabled by setting `CLAUDE_CODE_ATTRIBUTION_HEADER=0` in the **client's** `~/.claude/settings.json` under `env`. This is the dominant fix.
2. As a server-side fallback, `~/.claude-code-router/plugins/strip-billing-header.js` filters that block on the server. Kept registered in case a client forgets the env var or runs an older version.

## Key files and locations on the deployed host

- `~/llama.cpp/` — source checkout; rebuilt with `cmake --build build --config Release -j$(nproc)`. Symlinks `/usr/local/bin/llama-server` and `/usr/local/bin/llama-cli` point into `build/bin/`.
- `~/.models/` — GGUF weights. Currently includes the four files listed above plus the legacy 14B coder GGUF.
- `~/.claude-code-router/config.json` — router config; Anthropic key, router APIKEY, provider list including the local one with the `strip-billing-header` transformer.
- `~/.claude-code-router/plugins/strip-billing-header.js` — custom transformer (fallback for the billing header).
- `~/.claude-code-router/logs/ccr-<timestamp>.log` — per-launch ccr logs (rotates on each restart). `LOG: true` is enabled in config.
- `~/.config/llama-swap/config.yaml` — per-model `cmd` lines, `groups` (gpu / cpu), and `ttl`.
- `/etc/systemd/system/llama-swap.service`, `/etc/systemd/system/ccr.service` — unit files; both run as user `alex`.

## Client setup (Windows + Claude Code)

The Windows client should put **all** AI configuration in `C:\Users\<user>\.claude\settings.json` under `env` (not as Windows shell variables — CC reads from settings.json, and the shell takes precedence only if both are set, which is confusing):

```json
{
  "env": {
    "CLAUDE_CODE_ATTRIBUTION_HEADER": "0",
    "CLAUDE_CODE_SUBAGENT_MODEL": "claude-haiku-4-5",
    "ANTHROPIC_BASE_URL": "http://192.168.1.199:3456",
    "ANTHROPIC_AUTH_TOKEN": "<router APIKEY from config.json>",
    "ANTHROPIC_API_KEY": ""
  }
}
```

`CLAUDE_CODE_SUBAGENT_MODEL` is set to a haiku model id that ccr's `local` provider claims, so subagents without an explicit model run on the local Qwen 7B for free. Subagents with their own model declaration are unaffected.

## Editing rules specific to this doc

- **Token placeholders are intentional.** `sk-llama-cpp-CAMBIAR-POR-TOKEN-PROPIO` and `sk-ant-TU-API-KEY-ANTHROPIC` must stay as placeholders — never substitute a real key, even if the user pastes one. If a real key appears, flag it and ask before committing.
- The router APIKEY in `~/.claude-code-router/config.json` and the Windows `ANTHROPIC_AUTH_TOKEN` are the **same value**. Change one → change all uses.
- Ports (`8001`, `3456`, `3000`) and the host IP `192.168.1.199` appear in multiple sections. Treat them as global constants — search-and-replace across the whole doc when changed.
- The legacy `ccr.service` unit declares `Wants=`/`After=llama-server.service`. That unit name does not exist on this host (we use `llama-swap.service`); it's a harmless dangling reference. If you ever recreate the unit file, point it at `llama-swap.service` instead.
- CUDA arch is pinned to `60` (Pascal / P100). Don't change without confirming the target GPU.
- README.md and the install script are in English; keep new content in English.

## Common verification commands

```bash
# Service health
systemctl is-active llama-swap ccr
docker ps --filter name=open-webui

# What models llama-swap exposes and which is loaded
curl -sS http://localhost:8001/v1/models | jq
curl -sS http://localhost:8001/running | jq

# Anthropic-side smoke test through ccr
curl -sS -X POST -H "Authorization: Bearer <router APIKEY>" \
     -H "Content-Type: application/json" -H "anthropic-version: 2023-06-01" \
     http://localhost:3456/v1/messages \
     -d '{"model":"claude-sonnet-4-6","max_tokens":50,"messages":[{"role":"user","content":"hi"}]}'

# Tail ccr's per-turn timings (find prompt_n / cache_n / predicted_per_second)
LOG=~/.claude-code-router/logs/$(ls -t ~/.claude-code-router/logs/ | head -1)
grep '"timings"' "$LOG" | tail

# Live logs
sudo journalctl -u llama-swap -f
sudo journalctl -u ccr -f
docker logs -f open-webui
```
