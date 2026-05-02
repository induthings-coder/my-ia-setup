# my-ia-setup

A reproducible bare-metal install of a **hybrid AI server**: local
[`llama.cpp`](https://github.com/ggml-org/llama.cpp) models on a single
NVIDIA GPU, plus the Anthropic API, routed transparently behind a single
endpoint. One Bash script (`my-ia-setup-install.sh`) brings the box from
fresh Ubuntu 24.04 to a fully working stack — idempotent, version-checked
at every step.

The setup serves two distinct audiences from the same machine:

- **Professional use** — Claude Code (or any Anthropic-compatible client)
  hits a single URL and gets routed to Sonnet / Opus / a local model
  based on the kind of request.
- **Family / casual use** — Open WebUI in the browser, model picker shows
  every locally-served model, and switching costs one click.

---

## Architecture

```
┌──────────────────────────────────────────────────────────────────────┐
│  Clients                                                             │
│   • Windows + Claude Code           (work)                           │
│   • Any device + browser            (Open WebUI)                     │
└─────────────────────┬───────────────────────┬────────────────────────┘
                      │                       │
                      ▼                       ▼
┌────────────────────────────┐   ┌──────────────────────────────────────┐
│ claude-code-router (ccr)   │   │ Open WebUI (Docker)                  │
│ :3456 — Anthropic-compat   │   │ :3000 — ChatGPT-style UI             │
│   default → Sonnet 4.6     │   │                                      │
│   think   → Opus 4.7       │   │     OpenAI-compatible client         │
│   long    → Opus 4.7       │   │           ↓                          │
│   bg      → local          │   └──────────────────────┬───────────────┘
└─────────────┬──────────────┘                          │
              │                                         │
              └─────────────────┬───────────────────────┘
                                ▼
                  ┌────────────────────────────────┐
                  │ llama-swap                     │
                  │ :8001 — model proxy            │
                  │   on-demand spawns llama-server│
                  │   per requested model id       │
                  └─────────────┬──────────────────┘
                                ▼
                  ┌────────────────────────────────┐
                  │ llama-server (one at a time)   │
                  │   • Qwen2.5-14B-Instruct       │
                  │   • Gemma-3-4B-it + mmproj     │
                  └────────────────────────────────┘
```

### Why llama-swap?

A single GPU can hold one large model at a time. `llama-swap` listens on
:8001, parses each incoming request's `model` field, starts the matching
`llama-server` if it isn't already loaded, proxies the request, and unloads
idle models after a configurable TTL. From the client side it looks like a
multi-model OpenAI-compatible endpoint.

This means the family can switch from "coder" (Qwen2.5-14B) to "familiar"
(Gemma 3 with vision) directly from Open WebUI's model dropdown. No SSH,
no scripts, no buttons.

---

## Hardware

Tested and verified on:

| Component | Spec                                  |
| --------- | ------------------------------------- |
| CPU       | Intel Xeon E5-2695 v4 (18C/36T)       |
| RAM       | 48 GB DDR4                            |
| GPU       | NVIDIA Tesla P100 16 GB (Pascal, CC 6.0) |
| Storage   | ~50 GB free for models + builds       |

The installer enforces the following minimums (override via env vars):

| Check               | Default minimum | Override                |
| ------------------- | --------------- | ----------------------- |
| NVIDIA driver       | 535             | `MIN_DRIVER_VERSION`    |
| GPU compute capability | 6.0          | (hard-coded)            |
| VRAM                | 16 GB           | `MIN_VRAM_GB`           |
| CUDA arch flag      | 60 (Pascal)     | `CUDA_ARCH`             |

If your GPU is newer (Ampere/Ada/Hopper), set `CUDA_ARCH=86`, `89`, or `90`
respectively before running the installer.

---

## Software stack

| Component            | Version (verified)        | Purpose                                                  |
| -------------------- | ------------------------- | -------------------------------------------------------- |
| Ubuntu               | 24.04 LTS                 | Host OS                                                  |
| NVIDIA driver        | ≥ 535                     | GPU access                                               |
| CUDA toolkit         | 12.4                      | Build llama.cpp with GPU offload                         |
| Python               | ≥ 3.10                    | `huggingface_hub` for model downloads                    |
| Node.js              | 20.x                      | Runs `claude-code-router`                                |
| Docker               | ≥ 24                      | Hosts Open WebUI                                         |
| llama.cpp            | head of `master`          | Built with `-DGGML_CUDA=ON -DCMAKE_CUDA_ARCHITECTURES=60`|
| llama-swap           | v210                      | Model proxy, sha256-pinned                               |
| claude-code-router   | latest npm                | Anthropic-compatible router                              |
| Open WebUI           | `ghcr.io/open-webui/open-webui:main` | Web chat UI                                   |

### Models downloaded by default

| Model                                          | Size (Q-quant) | Used as          |
| ---------------------------------------------- | -------------- | ---------------- |
| `Qwen2.5-14B-Instruct-Q4_K_M.gguf`             | ~9 GB          | Coding / general |
| `google_gemma-3-4b-it-Q5_K_M.gguf` + mmproj-f16 | ~3.6 GB        | Family chat + vision |

---

## Quick start

On a fresh Ubuntu 24.04 box with NVIDIA drivers already installed:

```bash
# Clone the repo
git clone https://github.com/induthings-coder/my-ia-setup.git
cd my-ia-setup

# Run the installer (will prompt for your Anthropic API key)
ANTHROPIC_API_KEY=sk-ant-... ./my-ia-setup-install.sh
```

Run as your normal user (the script refuses to run as root and uses `sudo`
where it must). On first run the script:

1. Verifies hardware and drivers
2. Installs APT packages, CUDA, Python, Node.js, Docker
3. Builds llama.cpp with the right CUDA arch
4. Downloads the GGUF models (~13 GB total)
5. Installs `claude-code-router` (npm) and `llama-swap` (binary, sha256-pinned)
6. Writes `~/.claude-code-router/config.json` (mode 0600) and
   `~/.config/llama-swap/config.yaml`
7. Installs systemd units, helper scripts, and a narrow sudoers dropin
8. Pulls and starts the Open WebUI container
9. Verifies all three endpoints with HTTP probes

Subsequent runs skip every step that already looks correct (existing models
keep their files, configs are reused, the binary version of `llama-swap`
is checked against the pinned tag).

### Output

At the end the installer prints something like:

```
ccr endpoint  : http://192.168.1.199:3456
ccr APIKEY    : sk-llama-cpp-XXXXXXXXXXXXXXXXXXXXXXXX
Open WebUI    : http://192.168.1.199:3000
```

Use the printed APIKEY as `ANTHROPIC_AUTH_TOKEN` on Claude Code clients.

---

## Configuration

All knobs are environment variables, set when invoking the installer.

| Variable                | Default       | What it does                                                     |
| ----------------------- | ------------- | ---------------------------------------------------------------- |
| `TARGET_USER`           | `$USER`       | Owner of the stack (configs go to that user's home)              |
| `ANTHROPIC_API_KEY`     | (prompted)    | Live key for ccr's Anthropic provider                            |
| `CCR_APIKEY`            | (generated)   | Token shared with Claude Code clients                            |
| `LLAMA_SWAP_VERSION`    | `v210`        | Pin to a specific llama-swap release                             |
| `LLAMA_SWAP_SHA256`     | (per version) | Override the expected SHA256 if pinning a different version      |
| `CUDA_ARCH`             | `60`          | CUDA arch passed to llama.cpp (Pascal=60, Ampere=86, Hopper=90)  |
| `MIN_DRIVER_VERSION`    | `535`         | Lower bound for NVIDIA driver                                    |
| `MIN_VRAM_GB`           | `16`          | Warn if GPU has less                                             |
| `SKIP_MODELS=1`         | unset         | Don't download GGUFs (use ones already in `~/.models/`)          |
| `SKIP_DOCKER=1`         | unset         | Don't (re)create the Open WebUI container                        |
| `ASSUME_YES=1`          | unset         | Don't prompt for confirmation (e.g. CUDA install)                |

### Restoring after a wipe (no re-download)

If you have a backup of `~/.models/` (the GGUF files) and the Open WebUI
volume tarball:

```bash
# Restore models
cp -av /backup/.models/* ~/.models/

# Restore Open WebUI data
docker volume create open-webui
docker run --rm -v open-webui:/data -v /backup:/restore alpine \
  tar xzf /restore/open-webui-volume.tar.gz -C /data

# Skip those two steps in the installer
SKIP_MODELS=1 ANTHROPIC_API_KEY=sk-ant-... ./my-ia-setup-install.sh
```

The installer reuses the existing `ANTHROPIC_API_KEY` and `CCR_APIKEY`
from `~/.claude-code-router/config.json` if you also restored that file.

---

## Client setup — Windows + Claude Code

Once the server is running, point Claude Code on a Windows client at the
router. Anything the client does is routed by ccr based on the
[Routing matrix](#routing) below.

### 1. Verify network reachability

In PowerShell:

```powershell
Test-NetConnection <server-ip> -Port 3456
```

Expect `TcpTestSucceeded : True`. If it fails, the server's firewall is
blocking inbound on `:3456` (ccr binds `0.0.0.0`, so only the firewall
should be in the way).

### 2. Install Claude Code

Install Node.js 20.x LTS from <https://nodejs.org/>, then in CMD or
PowerShell (regular user, not admin):

```cmd
npm install -g @anthropic-ai/claude-code
claude --version
```

### 3. Configure environment variables

Open a fresh **CMD** window and run:

```cmd
setx ANTHROPIC_BASE_URL "http://<server-ip>:3456"
setx ANTHROPIC_AUTH_TOKEN "<the CCR_APIKEY printed by the installer>"
setx ANTHROPIC_API_KEY ""
```

All three are required. The empty `ANTHROPIC_API_KEY` forces Claude Code
to use the bearer token you set instead of any Anthropic key it might
otherwise pick up from the environment.

The token is the `APIKEY` field in the server's
`~/.claude-code-router/config.json`. Treat it as a secret — anyone with
that token and the URL can spend Anthropic credits on your account.

**Close every CMD/PowerShell window** after `setx` — the new values are
only visible in terminals opened *after* the change.

### 4. First run

```cmd
cd C:\path\to\some\project
claude
```

Send a trivial prompt to confirm the round trip works.

### 5. Verify routing in real time

On the server, tail ccr's selection log:

```bash
tail -F ~/.claude-code-router/logs/ccr-*.log | grep -iE 'selected_provider|model|route'
```

Expected behaviour for a few common interactions:

| Client action                          | Route fired      | Backend                  | Costs API? |
| -------------------------------------- | ---------------- | ------------------------ | ---------- |
| Normal chat / code edits               | `default`        | Sonnet 4.6 (Anthropic)   | yes        |
| Auto-compaction of conversation        | `background`     | Qwen2.5-14B (local)      | no         |
| Extended thinking (`think harder`)     | `think`          | Opus 4.7 (Anthropic)     | yes (more) |
| Single message > `longContextThreshold` | `longContext`    | Opus 4.7 (Anthropic)     | yes        |

### 6. Troubleshooting (Windows side)

| Symptom                                  | First check                                                                                  |
| ---------------------------------------- | -------------------------------------------------------------------------------------------- |
| `ECONNREFUSED` / connection error        | ccr is down (`systemctl status ccr` on server) or firewall is blocking `:3456`.              |
| Claude Code returns `401 Unauthorized`   | `ANTHROPIC_AUTH_TOKEN` ≠ `APIKEY` in the server's `config.json`.                             |
| Asks you to log in / wants billing info  | `ANTHROPIC_API_KEY` was not blanked. Re-run `setx ANTHROPIC_API_KEY ""` then reopen the terminal. |
| First background call hangs ~10 s        | `llama-swap` is loading the local model on demand. Subsequent calls are instant until TTL.   |

### 7. Reverting to direct Anthropic mode

To bypass the router and talk to Anthropic directly (e.g. while debugging
the server):

```cmd
setx ANTHROPIC_BASE_URL ""
setx ANTHROPIC_AUTH_TOKEN ""
setx ANTHROPIC_API_KEY "sk-ant-your-personal-key"
```

Re-run the three `setx` commands from step 3 to switch back.

---

## Routing

`claude-code-router` chooses a backend per request based on its category.
The matrix below is what the installer writes to `config.json`.

| Route          | Backend                       | When it fires                                  |
| -------------- | ----------------------------- | ---------------------------------------------- |
| `default`      | `anthropic,claude-sonnet-4-6` | Normal interactive prompts                     |
| `background`   | `local,qwen2.5-14b`           | Auto-compactions, summarisation, tool calls    |
| `think`        | `anthropic,claude-opus-4-7`   | Extended-thinking requests                     |
| `longContext`  | `anthropic,claude-opus-4-7`   | Total tokens > `longContextThreshold` (60000)  |

### Cost knobs

- **Make most things free**: change `default` to `local,qwen2.5-14b` and drop
  `longContextThreshold` to ~30000 (below the local context window). Lower
  quality, near-zero API spend.
- **Custom router**: point `CUSTOM_ROUTER_PATH` at a JS module that inspects
  the request and decides per-prompt. Best cost/quality ratio.

---

## Switching the local model from a browser

Open WebUI:

1. **Settings → Connections** → click the ↻ icon next to the
   `localhost:8001/v1` connection.
2. In the chat model picker pick `qwen2.5-14b-coder` or
   `gemma-3-4b-familiar`.

`llama-swap` will spawn the matching `llama-server` (~5–10 s the first
time), proxy the request, and unload the previous model after `ttl: 600`
(10 min idle). The Anthropic side is unaffected.

To add a third model, edit `~/.config/llama-swap/config.yaml`:

```yaml
models:
  my-new-model:
    aliases: [my-new-model-short]
    cmd: |
      llama-server -m /home/alex/.models/<model>.gguf
        --ctx-size 16384 --n-gpu-layers 99
        --flash-attn on --jinja
        --host 127.0.0.1 --port ${PORT}
    ttl: 600
```

Then `sudo systemctl restart llama-swap.service`.

---

## Operations

All units run under systemd; user `alex` can manage stack services without
a password thanks to the `/etc/sudoers.d/ai-stack` dropin installed by the
script.

```bash
# Status of every stack component
systemctl status llama-swap ccr ai-healthcheck.timer ai-backup.timer
docker ps --filter name=open-webui

# Live logs
sudo journalctl -u llama-swap -f
sudo journalctl -u ccr -f
docker logs -f open-webui

# Manual healthcheck
~/ai-setup-docs/scripts/healthcheck.sh

# Manual backup
~/ai-setup-docs/scripts/backup.sh

# Update everything (rebuilds llama.cpp on git changes)
~/ai-setup-docs/scripts/update-stack.sh
```

### Healthcheck

`ai-healthcheck.timer` triggers `healthcheck.sh` every 5 minutes. The script
probes `:8001/v1/models`, `:3456/`, and `:3000/health`. On failure it logs
to journald and, if `NTFY_TOPIC` is set in
`/etc/systemd/system/ai-healthcheck.service`, posts to ntfy.sh.

### Backup

`ai-backup.timer` runs `backup.sh` daily at 03:00 (with up to 10 min jitter).
Output goes to `~/backups/ai-setup/<YYYY-MM-DD>/` and contains:

- `claude-code-router.tar.gz` — ccr config (logs and pid excluded)
- `llama-swap.tar.gz` — llama-swap YAML config
- `*.service` / `*.timer` — installed unit files
- `open-webui-volume.tar.gz` — full Open WebUI Docker volume

The script keeps the last 14 backups and prunes older ones.

### Update

`update-stack.sh` is **not** run automatically; invoke it on demand. It:

1. `git pull`s llama.cpp and rebuilds only if HEAD moved
2. `npm update -g` for `claude-code-router` and restarts the service if the
   version changed
3. `docker pull`s Open WebUI and recreates the container if the image
   digest changed

---

## File layout (on the server)

| Path                                          | Purpose                                            |
| --------------------------------------------- | -------------------------------------------------- |
| `~/.models/`                                  | GGUF model files                                   |
| `~/llama.cpp/`                                | Source checkout, rebuilt by `update-stack.sh`      |
| `/usr/local/bin/llama-server`                 | Symlink into `~/llama.cpp/build/bin/`              |
| `/usr/local/bin/llama-swap`                   | Pinned binary release                              |
| `~/.claude-code-router/config.json`           | ccr routing + Anthropic API key (mode 0600)        |
| `~/.config/llama-swap/config.yaml`            | Per-model cmd + aliases + ttl                      |
| `~/ai-setup-docs/`                            | Source-of-truth tree mirroring `/etc/systemd/...`  |
| `~/ai-setup-docs/systemd/`                    | All unit files                                     |
| `~/ai-setup-docs/scripts/`                    | healthcheck, backup, update-stack                  |
| `~/ai-setup-docs/sudoers.d/ai-stack`          | NOPASSWD rules (narrow scope)                      |
| `~/backups/ai-setup/<date>/`                  | Daily backup output                                |
| `/etc/systemd/system/{llama-swap,ccr,ai-*}.{service,timer}` | Installed units                |
| `/etc/sudoers.d/ai-stack`                     | Installed sudoers dropin                           |

---

## Repo layout

```
my-ia-setup/
├── my-ia-setup-install.sh   # The installer. ~900 lines, idempotent.
├── CLAUDE.md                # Working notes for Claude Code agents.
├── README.md                # This file.
└── .gitignore
```

The installer is intentionally a single self-contained file; it generates
the entire `~/ai-setup-docs/` tree on the target host so the deployed copy
is the source of truth at runtime.

---

## Security

| Concern                | Handling                                                                              |
| ---------------------- | ------------------------------------------------------------------------------------- |
| Anthropic API key      | Stored in `~/.claude-code-router/config.json`, mode `0600`, owned by stack user only. |
| ccr APIKEY             | Generated per-install via `openssl rand -hex 12`; printed once to operator.           |
| Privileged operations  | Sudoers dropin allows only specific `systemctl` actions on the four stack units.      |
| External binary        | `llama-swap` SHA256 is hardcoded for the pinned version; mismatch aborts install.     |
| Open WebUI exposure    | Listens on `0.0.0.0:3000` by default — fine on a LAN; put behind a reverse proxy if   |
|                        | exposed publicly.                                                                     |
| ccr exposure           | Listens on `0.0.0.0:3456` and **requires** the APIKEY in every request.               |

The installer never writes secrets to logs, never echoes them outside the
final summary, and refuses to overwrite an existing config without backing
it up first.

---

## Updating versions

To pin a newer `llama-swap`:

```bash
LLAMA_SWAP_VERSION=v220 \
  LLAMA_SWAP_SHA256=<paste from GitHub release> \
  ./my-ia-setup-install.sh
```

To switch to a different GPU generation, set `CUDA_ARCH` (and update
`MIN_VRAM_GB` if needed). `MIN_DRIVER_VERSION` should track CUDA's
[driver compatibility table](https://docs.nvidia.com/deploy/cuda-compatibility/).

---

## Troubleshooting

| Symptom                                           | First check                                                                  |
| ------------------------------------------------- | ---------------------------------------------------------------------------- |
| `nvidia-smi: command not found`                   | NVIDIA proprietary driver isn't installed. Install it before this script.    |
| `nvcc` reports a version other than 12.4          | Install ran on a system with a different CUDA. The build still uses your `nvcc`; verify via `cmake --build` output. |
| Build fails on `cmake --build`                    | `nvcc -V`, `gcc -v`; CUDA 12.x typically requires gcc ≤ 12.                  |
| llama-swap unit `activating` forever              | Check `journalctl -u llama-swap`; usually a bad path in `config.yaml`.       |
| Open WebUI shows no models                        | Connection URL must end in `/v1`; click ↻ in the Connections panel.          |
| Claude Code returns 401 from ccr                  | `APIKEY` in `config.json` ≠ `ANTHROPIC_AUTH_TOKEN` on the client.            |
| Out-of-memory on model load                       | Drop `--ctx-size`, or reduce `--n-gpu-layers` to offload some layers to CPU. |
| Healthcheck always reports DEGRADED               | Run `~/ai-setup-docs/scripts/healthcheck.sh` directly to see which probe fails. |
| Install loops on the same step                    | Re-run with `bash -x ./my-ia-setup-install.sh` to see what each `ensure_*` decides. |

---

## Verified versions

| Component         | Pinned / tested            |
| ----------------- | -------------------------- |
| Ubuntu            | 24.04 LTS                  |
| NVIDIA driver     | 550.x                      |
| CUDA              | 12.4                       |
| Python            | 3.12                       |
| Node.js           | 20.x                       |
| Docker            | 24.x                       |
| llama-swap        | v210 (sha256 pinned)       |
| claude-code-router| 2.0.x                      |
| Open WebUI image  | `:main` (rolling)          |

---

## License

No license has been specified yet. Treat this repository as "all rights
reserved" until a `LICENSE` file is added. If you intend to reuse the
installer in your own infrastructure, open an issue on the repo first.
