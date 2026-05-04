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

Three groups instead of one big swap-on-everything group:

- `gpu` — `qwen2.5-coder-7b` + `gemma-3-4b-familiar`, `swap: false`. Both coexist permanently on the P100 (~13.5 GB combined, ~2.5 GB headroom). `ttl: 0` and a `hooks.on_startup.preload` list keep them resident from boot.
- `gpu-heavy` — `qwen2.5-14b-coder`, `exclusive: true`. Opt-in only. Requesting it unloads the gpu pair (because the gpu group is non-persistent). After `ttl: 600` the 14B unloads, but the gpu pair does **not** auto-reload — it comes back on the next request. To force the preload state again, `sudo systemctl restart llama-swap`.
- `cpu` — `deepseek-r1-distill-7b`, `persistent: true`. Always resident in RAM. Survives the gpu-heavy eviction because of `persistent: true`. Also preloaded at startup.

Caveat: while the 14B is resident, requesting a non-exclusive group's member (e.g. the 7B) does **not** evict the 14B. The request OOMs and returns 502. This is `llama-swap`'s legacy-groups semantics — only `exclusive: true` triggers cross-group unloads.

### Why the P100 needs special handling

Pascal (compute capability 6.0, no Tensor Cores, no DP4A) is slow for prefill on quantized 14B+ models with `--flash-attn` and quantized KV cache. The 7B coder model with `--flash-attn off` and `f16` KV cache hits ~430 t/s prefill, fast enough for Claude Code's ~28 K-token system prompt to be tolerable when prompt-cache reuse works.

Prompt-cache reuse (the difference between a 70 s turn and a 1 s turn) only works when the prompt prefix is byte-stable between turns. Two known sources of churn:

1. **Claude Code's `x-anthropic-billing-header`** (CC ≥ 2.1.36 injects a per-turn `cch=...` token in the first system block). Disabled by setting `CLAUDE_CODE_ATTRIBUTION_HEADER=0` in the **client's** `~/.claude/settings.json` under `env`. This is the dominant fix.
2. As a server-side fallback, `~/.claude-code-router/plugins/strip-billing-header.js` filters that block on the server. Kept registered in case a client forgets the env var or runs an older version.

### GPU layout and the persistence daemon (load-bearing, easy to break)

The host has **two NVIDIA GPUs**, deliberately split between drivers:

| PCI | GPU | Driver | Role |
| --- | --- | --- | --- |
| `03:00.0` | Tesla P100 16 GB (Pascal) | `nvidia` (proprietary 535.x) | CUDA / `llama-server` |
| `04:00.0` | GeForce GT 730 (Kepler) | `nouveau` | Local display only |

The GT 730 is Kepler — the 535 proprietary driver explicitly refuses it (`NVRM: ... will ignore this GPU`), which is fine because `nouveau` drives it for the desktop. `prime-select` is set to `on-demand`. **Do not "fix" this by switching `prime-select` to `nvidia` or installing the 470 legacy driver** — both break CUDA on the P100 (the 7B model silently falls back to CPU at ~7 t/s instead of ~40 t/s).

**`nvidia-persistenced` must be running** for CUDA to work at all. Without it, the `nvidia` kernel module unloads whenever no process holds a handle, and the next `cuInit()` races against the unload and fails with `unknown error` (CUDA error 999). The Ubuntu-shipped unit file is wrong for a server: it has `StopWhenUnneeded=true` and `--no-persistence-mode`. Two drop-ins fix that:

- `/etc/systemd/system/nvidia-persistenced.service.d/override.conf`
  - clears `StopWhenUnneeded`
  - replaces `ExecStart` with `/usr/bin/nvidia-persistenced --user nvidia-persistenced --verbose` (no `--no-persistence-mode`)
- `/etc/systemd/system/llama-swap.service.d/nvidia-persistenced.conf`
  - adds `Wants=nvidia-persistenced.service` and `After=nvidia-persistenced.service` so the daemon is pulled up by llama-swap and stays up while it runs

Symptoms that this is broken: `nvidia-smi` looks fine, `qwen2.5-coder-7b` answers correctly, but `predicted_per_second ≈ 7` and `nvidia-smi` shows `0 MiB / 0 %` during inference. `dmesg` shows a tight loop of `nvidia-modeset: Unloading` / `Loading` while a CUDA process is alive.

## Key files and locations on the deployed host

- `~/llama.cpp/` — source checkout; rebuilt with `cmake --build build --config Release -j$(nproc)`. Symlinks `/usr/local/bin/llama-server` and `/usr/local/bin/llama-cli` point into `build/bin/`.
- `~/.models/` — GGUF weights. Currently includes the four files listed above plus the legacy 14B coder GGUF.
- `~/.claude-code-router/config.json` — router config; Anthropic key, router APIKEY, provider list including the local one with the `strip-billing-header` transformer.
- `~/.claude-code-router/plugins/strip-billing-header.js` — custom transformer (fallback for the billing header).
- `~/.claude-code-router/logs/ccr-<timestamp>.log` — per-launch ccr logs (rotates on each restart). `LOG: true` is enabled in config.
- `~/.config/llama-swap/config.yaml` — per-model `cmd` lines, `groups` (gpu / cpu), and `ttl`.
- `/etc/systemd/system/llama-swap.service`, `/etc/systemd/system/ccr.service` — unit files; both run as user `alex`.
- `/etc/systemd/system/nvidia-persistenced.service.d/override.conf` — keeps the persistence daemon alive in real persistence mode (load-bearing for CUDA; see the persistence-daemon section above).
- `/etc/systemd/system/llama-swap.service.d/nvidia-persistenced.conf` — pulls the persistence daemon up as a dependency of llama-swap.
- `/etc/modprobe.d/gt730-fix.conf` — `nouveau modeset=1` so the GT 730 drives the desktop.
- `/etc/modprobe.d/nvidia-graphics-drivers-kms.conf` — Ubuntu package-managed, sets `nvidia-drm modeset=0`. Don't add other `NVreg_*` files here without checking `dmesg` for `unknown parameter ... ignored`; the 535 driver silently drops anything it doesn't recognise.
- `/etc/X11/xorg.conf.d/10-gt730-only.conf` — pins Xorg to the GT 730 (`Driver "modesetting"`, `BusID "PCI:4:0:0"`, `kmsdev=/dev/dri/card0`), and forces `1920x1080` via a `Monitor` + `Screen.Display.Modes` block. The GT 730 is Kepler GK208B with HDMI 1.4 only (~340 MHz pixel clock cap); a 4K display's preferred mode (3840x2160@60Hz, 533 MHz) needs HDMI 2.0/SCDC, so nouveau fails the SCDC handshake (`Failure to read SCDC_TMDS_CONFIG: -6`, `kmsOutp ret:-22`) and the screen stays black even though Xorg reports the modeset succeeded. Without the pin Xorg picks the P100 first by PCI order and dies with `(EE) [drm] Failed to open DRM device for (null): -2` because `nvidia-drm modeset=0`. Use `modesetting`, not the legacy UMS `nouveau` Xorg driver (the latter trips on `xf86EnableIO: failed to enable I/O ports`).
- `gdm` user must be in groups `video` and `render` (`sudo usermod -aG video,render gdm`) so Xorg launched by gdm can open `/dev/fb0` and `/dev/dri/card0`. Symptom of missing membership: `(EE) open /dev/fb0: Permission denied` in `/var/lib/gdm3/.local/share/xorg/Xorg.0.log` and gdm looping on `GdmDisplay: Session never registered, failing`.
- `/etc/udev/rules.d/99-hide-p100-from-desktop.rules` strips the P100's `drm` and `graphics` nodes from `seat0` (`TAG-="seat"` + empty `ID_FOR_SEAT`). Without this, logind tries to expose the P100 as a graphics device for any Xorg session and `(EE) systemd-logind: failed to take device /dev/dri/card1: No such device` shows up in the Xorg log; on some boots this escalates from informational to a startup failure.
- `fix-gpu.service` (oneshot, `Before=display-manager.service`, runs `/usr/local/bin/fix-gpu-drivers.sh`) unbinds the P100 from `nouveau` and `modprobe`s `nvidia` + `nvidia_uvm` before GDM starts. Required because early-boot probing can attach `nouveau` to both GPUs; without this fix-up the P100 sometimes ends up under `nouveau` and CUDA fails until reboot.
- An older `/etc/X11/xorg.conf.d/00-video.conf` is retained alongside `10-gt730-only.conf`. Its only useful section now is `Device "P100" / Driver "nvidia" / Option "Ignore" "yes"`; the `GT730` and `Screen0` sections it also defines are superseded by `10-gt730-only.conf` because of lexical merge order. Do not delete `00-video.conf` without re-homing the `Ignore` somewhere.
- `INVENTORY.md` (in this repo) holds a full snapshot of the live host (hardware, drivers, modprobe, udev, Xorg, systemd, ports, models). Update it when the deployed state changes.

## Client setup (Windows + Claude Code)

The Windows client should put **all** AI configuration in `C:\Users\<user>\.claude\settings.json` under `env` (not as Windows shell variables — CC reads from settings.json, and the shell takes precedence only if both are set, which is confusing). The intended balance is **Sonnet 4.6 for the main conversation, Qwen 7B for everything cheap (haiku tier, subagents, summarization), Opus 4.7 only when explicitly requested via `/think` or auto-promoted by `longContext`**. ccr already enforces that routing — the client config just rides it:

```json
{
  "env": {
    "ANTHROPIC_BASE_URL": "http://192.168.1.199:3456",
    "ANTHROPIC_AUTH_TOKEN": "<router APIKEY from config.json>",
    "ANTHROPIC_API_KEY": "",

    "ANTHROPIC_SMALL_FAST_MODEL": "claude-haiku-4-5",
    "CLAUDE_CODE_SUBAGENT_MODEL": "claude-haiku-4-5",

    "CLAUDE_CODE_ATTRIBUTION_HEADER": "0",
    "CLAUDE_CODE_ENABLE_TELEMETRY": "0",
    "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1",
    "DISABLE_NON_ESSENTIAL_MODEL_CALLS": "1",
    "DISABLE_COST_WARNINGS": "1",
    "DISABLE_MICROCOMPACT": "1",
    "CLAUDE_CODE_DISABLE_FINE_GRAINED_TOOL_STREAMING": "1",

    "API_TIMEOUT_MS": "600000",
    "BASH_DEFAULT_TIMEOUT_MS": "120000"
  },
  "permissions": { "defaultMode": "auto" },
  "skipAutoPermissionPrompt": true
}
```

Both `ANTHROPIC_SMALL_FAST_MODEL` and `CLAUDE_CODE_SUBAGENT_MODEL` point at `claude-haiku-4-5`, which the ccr `local` provider claims and routes to Qwen 7B locally — so haiku-tier internal calls (title generation, prompt expansion, summarization) and subagents without an explicit model are free. Anthropic-issued IDs (`claude-haiku-4-5`) are preferred over passing the raw local model id (`qwen2.5-coder-7b`) so the same `settings.json` keeps working if ccr is bypassed or replaced.

**Pitfalls to actively avoid in this file:**

- A top-level `"model": "claude-haiku-4-5"` (or any haiku-tier id) sends every conversation turn through the local Qwen 7B because of the same provider claim. That destroys the Sonnet/Opus balance — only set `model` if you truly want all turns local.
- `"DISABLE_PROMPT_CACHING": "1"` looks like a cost-saver but is the opposite: it removes Anthropic's ~90% prefix-cache discount, so every Sonnet/Opus turn pays full input cost. Leave prompt caching enabled.
- `ANTHROPIC_DEFAULT_HAIKU_MODEL` is **not** a Claude Code variable — `ANTHROPIC_SMALL_FAST_MODEL` is the real name. Setting the wrong one is a silent no-op.
- An `API_TIMEOUT_MS` ≤ 120 s will time out long Opus + thinking + tool-use turns, which are the ones it is most worth waiting for. Match the server-side `API_TIMEOUT_MS` in `~/.claude-code-router/config.json` (600 s).

## Editing rules specific to this doc

- **Token placeholders are intentional.** `sk-llama-cpp-CAMBIAR-POR-TOKEN-PROPIO` and `sk-ant-TU-API-KEY-ANTHROPIC` must stay as placeholders — never substitute a real key, even if the user pastes one. If a real key appears, flag it and ask before committing.
- The router APIKEY in `~/.claude-code-router/config.json` and the Windows `ANTHROPIC_AUTH_TOKEN` are the **same value**. Change one → change all uses.
- Ports (`8001`, `3456`, `3000`) and the host IP `192.168.1.199` appear in multiple sections. Treat them as global constants — search-and-replace across the whole doc when changed.
- The legacy `ccr.service` unit declares `Wants=`/`After=llama-server.service`. That unit name does not exist on this host (we use `llama-swap.service`); it's a harmless dangling reference. If you ever recreate the unit file, point it at `llama-swap.service` instead.
- CUDA arch is pinned to `60` (Pascal / P100). Don't change without confirming the target GPU.
- README.md and the install script are in English; keep new content in English.
- The host has a second NVIDIA GPU (GT 730) for the desktop. **Don't propose `prime-select nvidia`, swapping to the 470 legacy driver, or "consolidating" the two drivers** — those changes break CUDA on the P100. The intended layout is `nvidia` for `03:00.0` only, `nouveau` for `04:00.0`.
- `nvidia-persistenced` is part of the runtime contract, not optional. If you see it stopped or `Disabled`, the GPU path is broken regardless of what `nvidia-smi` says.

## Common verification commands

```bash
# Service health (note: nvidia-persistenced is required for GPU inference)
systemctl is-active nvidia-persistenced llama-swap ccr
docker ps --filter name=open-webui

# Confirm GPU is actually being used (not silent CPU fallback)
nvidia-smi --query-gpu=persistence_mode,memory.used,utilization.gpu --format=csv
# After hitting a model: persistence=Enabled, memory ~8.6 GB, util > 0.
# If memory stays at 0 MiB while the model answers, you're on CPU; check
# nvidia-persistenced and `dmesg | grep nvidia-modeset`.

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
