# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository purpose

This repo holds the deployment documentation (not code) for a hybrid AI server: an Ubuntu 24.04 host (192.168.1.199, Xeon E5-2695 v4 / 48GB RAM / NVIDIA P100 16GB) that combines a local GGUF model on GPU with the Anthropic API, exposed to two distinct client surfaces.

Edits here are documentation changes. There is no build, lint, or test pipeline. Verify changes by re-reading `README.md` and confirming that the commands, ports, paths, and config snippets are internally consistent.

## Architecture (the big picture)

Three services run on the host, each with a fixed role. Get these relationships right before editing anything:

- **`llama-server`** (port `8001`) — llama.cpp serving `Qwen2.5-14B-Instruct-Q4_K_M.gguf` from `~/.models/` on the P100. Exposes an OpenAI-compatible API at `/v1`. Started by `systemd` unit `llama-server.service`.
- **`claude-code-router` / `ccr`** (port `3456`) — Anthropic-compatible front door for Claude Code clients. Routes requests by category using `~/.claude-code-router/config.json`:
  - `default` → Anthropic Sonnet 4.6
  - `background` → local Qwen2.5-14B (free)
  - `think` → Anthropic Opus 4.7
  - `longContext` (>60K tokens) → Anthropic Opus 4.7
  Started by `ccr.service`, which `Requires=llama-server.service` so the local provider is reachable on boot.
- **Open WebUI** (port `3000`, Docker `--network host`, `--restart always`) — ChatGPT-style UI for non-technical users. Talks **directly** to `llama-server` at `http://localhost:8001/v1`, **not** through `ccr`. Only `ccr` brokers Anthropic traffic.

Two client paths matter:
1. Windows + Claude Code → `ccr` (env vars `ANTHROPIC_BASE_URL=http://192.168.1.199:3456`, `ANTHROPIC_AUTH_TOKEN=<router APIKEY>`, `ANTHROPIC_API_KEY=""`).
2. Browser → Open WebUI → `llama-server` (local-only path).

## Key files and locations on the deployed host

- `~/llama.cpp/` — source checkout; rebuilt with `cmake --build build --config Release -j$(nproc)`. Symlinks `/usr/local/bin/llama-server` and `/usr/local/bin/llama-cli` point into `build/bin/`.
- `~/.models/` — GGUF weights (Qwen2.5-14B is mandatory; Mistral 7B and Gemma 3 4B + mmproj are optional).
- `~/.claude-code-router/config.json` — router config; holds the Anthropic key and the router-facing `APIKEY` shared with Claude Code clients.
- `/etc/systemd/system/llama-server.service`, `/etc/systemd/system/ccr.service` — unit files; both run as user `alex`.

## Editing rules specific to this doc

- **Token placeholders are intentional.** `sk-llama-cpp-CAMBIAR-POR-TOKEN-PROPIO` and `sk-ant-TU-API-KEY-ANTHROPIC` must stay as placeholders — never substitute a real key, even if the user pastes one. If a real key appears, flag it and ask before committing.
- The router APIKEY in `config.json`, the curl test in §7.2, and the Windows `ANTHROPIC_AUTH_TOKEN` in §8 are the **same value**. Change one → change all three.
- Ports (`8001`, `3456`, `3000`) and the host IP `192.168.1.199` appear in multiple sections. Treat them as global constants — search-and-replace across the whole doc when changed.
- `ccr.service` declares `Requires=llama-server.service`. If you remove the local provider from the routing config, also drop that `Requires=` so `ccr` can still start.
- CUDA arch is pinned to `60` (Pascal / P100). Don't change without confirming the target GPU.
- The doc is in Spanish; keep new content in Spanish to match.

## Common verification commands

```bash
# Service health
sudo systemctl status llama-server ccr
sudo docker ps

# Endpoint smoke tests
curl http://localhost:8001/health
curl -X POST -H "Authorization: Bearer <router APIKEY>" \
     -H "Content-Type: application/json" -H "anthropic-version: 2023-06-01" \
     http://localhost:3456/v1/messages \
     -d '{"model":"claude-sonnet-4-6","max_tokens":50,"messages":[{"role":"user","content":"hi"}]}'

# Live logs
sudo journalctl -u llama-server -f
sudo journalctl -u ccr -f
sudo docker logs -f open-webui
```
