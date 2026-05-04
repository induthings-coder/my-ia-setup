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
│   bg      → local 7B coder │   └──────────────────────┬───────────────┘
│ + plugins/                 │                          │
│   strip-billing-header.js  │                          │
└─────────────┬──────────────┘                          │
              │                                         │
              └─────────────────┬───────────────────────┘
                                ▼
                  ┌────────────────────────────────────────┐
                  │ llama-swap                             │
                  │ :8001 — model proxy + group manager    │
                  └─────────────┬──────────────────────────┘
                                │
              ┌─────────────────┼──────────────────┐
              │ group: gpu      │ group: cpu       │
              │ (one at a time) │ (independent)    │
              ▼                 ▼                  ▼
   ┌──────────────────┐  ┌──────────────────┐  ┌──────────────────┐
   │ llama-server     │  │ llama-server     │  │ llama-server     │
   │ Qwen2.5-Coder-7B │  │ Gemma-3-4B+mmproj│  │ DeepSeek-R1      │
   │ (P100, default)  │  │ (P100, on demand)│  │ Distill Qwen 7B  │
   │ ─ alt: 14B       │  │                  │  │ (CPU, reasoning) │
   └──────────────────┘  └──────────────────┘  └──────────────────┘
```

### Why llama-swap and groups

A single GPU holds one large model at a time. `llama-swap` listens on
`:8001`, parses each incoming request's `model` field, starts the matching
`llama-server` if it isn't already loaded, proxies the request, and unloads
idle models after a configurable TTL. From the client side it looks like a
multi-model OpenAI-compatible endpoint.

The `groups` block in `~/.config/llama-swap/config.yaml` makes the swap
behavior precise: GPU models share one slot (loading any one unloads the
others, ~5–10 s cold-load latency the first time), while the CPU model lives
in its own group and **coexists** with the active GPU model. So you can keep
DeepSeek-R1 resident in RAM for reasoning tasks without evicting Qwen from
the GPU.

### Why the P100 needs special care

Pascal (compute capability 6.0) lacks Tensor Cores and DP4A. Quantized 14B
models with `--flash-attn` and Q8 KV cache hit ~170 t/s prefill — fine for
chat, painful for Claude Code prompts (28 K tokens of system + tools). The
tuning that makes the local path usable:

- **Qwen 2.5 Coder 7B** as the default local model (~430 t/s prefill,
  ~40 t/s gen on the P100). The 7B Coder beats the 14B Instruct on code
  benchmarks and runs 2–3× faster.
- **`f16` KV cache and no `--flash-attn`** in the 7B's `cmd` line — both
  Q8 KV and FA hurt on Pascal.
- **`--cache-reuse 256` and `--parallel 1`** so the single slot accumulates
  a long-lived KV prefix.
- **`CLAUDE_CODE_ATTRIBUTION_HEADER=0` in the client's `settings.json`**
  to stop the per-turn `cch=...` rotation that otherwise invalidates the
  prefix on every turn (`prompt_n=28553, cache_n=33` regardless of how
  long the conversation has been). With the flag set, the second turn's
  `cache_n` matches `prompt_n` and the wall-clock drops from ~70 s to
  ~1–3 s.

---

## Hardware

Tested and verified on:

| Component | Spec                                  |
| --------- | ------------------------------------- |
| CPU       | Intel Xeon E5-2695 v4 (18C/36T)       |
| RAM       | 48 GB DDR4                            |
| GPU 0 (compute) | NVIDIA Tesla P100 16 GB (Pascal, CC 6.0) — driven by the proprietary `nvidia` 535 driver, dedicated to CUDA |
| GPU 1 (display, optional) | NVIDIA GeForce GT 730 (Kepler GK208B) — driven by `nouveau`, used only for the local desktop (Kepler is unsupported by 535 and is intentionally ignored by it) |
| Storage   | ~50 GB free for models + builds       |

The Tesla P100 is the only GPU CUDA ever sees. The GT 730 is purely a video output card for the local desktop, kept on `nouveau`. See [GPU layout & nvidia-persistenced](#gpu-layout--nvidia-persistenced) for why the split matters.

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

### Models in `~/.models/`

| Model file                                          | Size (Q-quant) | Backend | Role |
| ---------------------------------------------------- | -------------- | ------- | ---- |
| `Qwen2.5-Coder-7B-Instruct-Q4_K_M.gguf`              | ~4.4 GB        | GPU     | **Default for Claude Code** (`background` route, fast on P100) |
| `Qwen2.5-14B-Instruct-Q4_K_M.gguf`                   | ~9 GB          | GPU     | Heavier alternative; slower on P100, kept opt-in              |
| `google_gemma-3-4b-it-Q5_K_M.gguf` + mmproj-f16      | ~3.6 GB        | GPU     | Family chat in Open WebUI, with vision                        |
| `DeepSeek-R1-Distill-Qwen-7B-Q4_K_M.gguf`            | ~4.4 GB        | CPU     | Reasoning model. Coexists with the active GPU model.          |

The first three live in the `gpu` swap group (only one resident at a time);
DeepSeek-R1 lives in its own `cpu` group and is independent.

> **Note on the installer.** `my-ia-setup-install.sh` currently only
> downloads the legacy 14B Instruct + Gemma. The 7B Coder and DeepSeek-R1
> were added post-install and are documented in
> [Post-install changes](#post-install-changes) below. A future revision of
> the installer should subsume that section.

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

### 3. Configure Claude Code via `settings.json` (preferred)

Claude Code reads its environment from `C:\Users\<user>\.claude\settings.json`
under the `env` key. Putting the configuration there (instead of using
Windows `setx` shell variables) is more portable, doesn't pollute the
PowerShell environment, and is easier to revert.

The goal of this file is a **balanced split** between Anthropic and the local
model: Sonnet 4.6 for the main conversation (precision when it matters), Opus
4.7 only when explicitly requested via `/think` or auto-promoted by long
context, and Qwen 7B local (free) for everything cheap — haiku-tier internal
calls and subagents. ccr already enforces that routing on the server side; the
`settings.json` below just rides it without contradicting it.

Edit (or create) `C:\Users\<user>\.claude\settings.json` so it contains:

```json
{
  "env": {
    "ANTHROPIC_BASE_URL": "http://<server-ip>:3456",
    "ANTHROPIC_AUTH_TOKEN": "<the CCR_APIKEY printed by the installer>",
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
  "autoUpdatesChannel": "latest",
  "theme": "dark",
  "skipAutoPermissionPrompt": true
}
```

Why each variable:

| Variable | What it does |
| --- | --- |
| `ANTHROPIC_BASE_URL` | Sends Claude Code traffic to ccr instead of `api.anthropic.com`. |
| `ANTHROPIC_AUTH_TOKEN` | Bearer token ccr requires (the `APIKEY` from the server's `~/.claude-code-router/config.json`). |
| `ANTHROPIC_API_KEY` | Must be empty so CC uses the bearer token, not any leftover Anthropic key. |
| `ANTHROPIC_SMALL_FAST_MODEL` | The "small/fast" model CC uses for title generation, prompt expansion, summarization. Pinned to `claude-haiku-4-5`, which ccr's `local` provider claims and routes to Qwen 7B locally — those calls are free. (`ANTHROPIC_DEFAULT_HAIKU_MODEL` is **not** a Claude Code variable, despite some forum posts using that name; setting it is a silent no-op.) |
| `CLAUDE_CODE_SUBAGENT_MODEL` | Pinned to the same haiku id, so subagents without an explicit model run on Qwen 7B for free. Subagents that declare their own model are unaffected. |
| `CLAUDE_CODE_ATTRIBUTION_HEADER` | Setting it to `"0"` stops CC from injecting the `x-anthropic-billing-header: ...; cch=...` block, whose per-turn rotation would otherwise invalidate the local model's KV cache on every turn. **Without this flag every turn pays a full ~70 s prefill.** |
| `CLAUDE_CODE_ENABLE_TELEMETRY` / `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC` / `DISABLE_NON_ESSENTIAL_MODEL_CALLS` | Disable telemetry and incidental model calls (UI heuristics, suggestion expansions). Reduces Anthropic spend without affecting core behaviour. |
| `DISABLE_MICROCOMPACT` | Skips automatic micro-compaction during the turn. Slightly less polished context handling, but every compaction turn is a free Anthropic call you avoid. |
| `CLAUDE_CODE_DISABLE_FINE_GRAINED_TOOL_STREAMING` | Drops fine-grained tool input streaming (a small UX downgrade, no functional impact) and saves a few small calls per tool invocation. |
| `DISABLE_COST_WARNINGS` | Quality-of-life only; suppresses the in-CLI cost dialog. |
| `API_TIMEOUT_MS` | 600 000 ms / 10 min. Long Opus + thinking + tool-use turns can exceed 120 s; matching the server's `API_TIMEOUT_MS` (in `~/.claude-code-router/config.json`) prevents intermittent client timeouts on the very requests it's most valuable to let finish. |
| `BASH_DEFAULT_TIMEOUT_MS` | Per-bash-call timeout, separate from the API timeout. 120 s suits typical commands; raise per-call with explicit timeouts when running builds. |

Save the file. Close every Claude Code window — settings are read at
startup, not on the fly.

**Anti-patterns to avoid in this file** (each looks like an optimisation but
breaks the intended balance):

- **`"model": "claude-haiku-4-5"` at the top level.** `claude-haiku-4-5` is one
  of the model IDs ccr's `local` provider claims, so a top-level pin sends
  *every* conversation turn — refactors, debugging, architecture — through
  Qwen 7B locally. That destroys the Sonnet/Opus precision the rest of the
  config is built to preserve. Only set `model` if you genuinely want all
  turns local.
- **`"DISABLE_PROMPT_CACHING": "1"`.** Looks like it saves money; in fact it
  removes Anthropic's ~90 % prefix-cache discount on the repeated system
  prompt, so every Sonnet/Opus turn after the first pays full input cost.
  Multiplies Anthropic spend by roughly 10×. Leave prompt caching on.
- **Any `ANTHROPIC_*` set in Windows "User variables" via `setx`.** Shell vars
  win over `settings.json` — easy to chase ghost behaviour. Remove every
  `ANTHROPIC_*` from the Windows environment dialog and let `settings.json`
  be the single source of truth.

The token is the `APIKEY` field in the server's
`~/.claude-code-router/config.json`. Treat it as a secret — anyone with
that token and the URL can spend Anthropic credits on your account.

### 4. First run

```cmd
cd C:\path\to\some\project
claude
```

Send a trivial prompt to confirm the round trip works.

### 5. Verify routing in real time

On the server, tail ccr's per-launch log (rotates on each restart):

```bash
LOG=~/.claude-code-router/logs/$(ls -t ~/.claude-code-router/logs/ | head -1)
tail -F "$LOG" | grep -iE 'selected_provider|model|background|"timings"'
```

Expected behaviour for a few common interactions:

| Client action                          | Route fired      | Backend                       | Costs API? |
| -------------------------------------- | ---------------- | ----------------------------- | ---------- |
| Normal chat / code edits               | `default`        | Sonnet 4.6 (Anthropic)        | yes        |
| Auto-compaction of conversation        | `background`     | Qwen2.5-Coder-7B (local, GPU) | no         |
| Extended thinking (`think harder`)     | `think`          | Opus 4.7 (Anthropic)          | yes (more) |
| Single message > `longContextThreshold` | `longContext`    | Opus 4.7 (Anthropic)          | yes        |
| Subagent without explicit model        | `background`     | Qwen2.5-Coder-7B (local, GPU) | no         |

#### Reading the per-turn timings

Each completed turn writes a `timings` block to the ccr log. The two
critical numbers are `prompt_n` (tokens in this turn's prompt) and
`cache_n` (tokens reused from the previous turn's KV cache):

```bash
grep '"timings"' "$LOG" | tail -1 | python3 -c '
import sys, json, re
m = re.search(r"\"timings\":\{[^}]*\}", sys.stdin.read())
t = json.loads("{"+m.group(0)+"}")["timings"]
print(f"prompt={t.get(\"prompt_n\")} cached={t.get(\"cache_n\")} prefill={t.get(\"prompt_per_second\",0):.0f}t/s gen={t.get(\"predicted_per_second\",0):.1f}t/s")'
```

Healthy second turn: `cached ≈ prompt`, `responseTime` 1–3 s. If `cached`
stays low (~30) across turns, the prompt prefix is rotating — most likely
`CLAUDE_CODE_ATTRIBUTION_HEADER=0` is missing from the client's
`settings.json` or the env var is being shadowed by a Windows shell var.

### 6. Troubleshooting (Windows side)

| Symptom                                  | First check                                                                                  |
| ---------------------------------------- | -------------------------------------------------------------------------------------------- |
| `ECONNREFUSED` / connection error        | ccr is down (`systemctl is-active ccr` on server) or firewall is blocking `:3456`.           |
| Claude Code returns `401 Unauthorized`   | `ANTHROPIC_AUTH_TOKEN` ≠ `APIKEY` in the server's `config.json`.                             |
| Asks you to log in / wants billing info  | `ANTHROPIC_API_KEY` was not blanked in `settings.json`, or a Windows shell var is shadowing it. Remove any user/system `ANTHROPIC_*` shell vars. |
| First background call hangs ~10 s        | `llama-swap` is loading the local model on demand. Subsequent calls are fast until TTL.      |
| Every turn takes ~70 s on the local model | `CLAUDE_CODE_ATTRIBUTION_HEADER` is missing or shadowed. Confirm `cache_n` in the ccr log.   |
| Server-side OOM after a model swap       | Long-running KV cache plus another model loading. `systemctl restart llama-swap` clears it.  |

### 7. Reverting to direct Anthropic mode

To bypass the router and talk to Anthropic directly (e.g. while debugging
the server), edit `settings.json` and remove the three `ANTHROPIC_*` keys
(or set `ANTHROPIC_API_KEY` to your real key and remove the other two).
Restart Claude Code. To switch back, restore the entries from step 3.

---

## Routing

`claude-code-router` chooses a backend per request based on its category.
The matrix below is what the installer writes to `config.json`.

| Route          | Backend                       | When it fires                                  |
| -------------- | ----------------------------- | ---------------------------------------------- |
| `default`      | `anthropic,claude-sonnet-4-6` | Normal interactive prompts                     |
| `background`   | `local,qwen2.5-coder-7b`      | Auto-compactions, summarisation, subagents w/o explicit model |
| `think`        | `anthropic,claude-opus-4-7`   | Extended-thinking requests                     |
| `longContext`  | `anthropic,claude-opus-4-7`   | Total tokens > `longContextThreshold` (60000)  |

The `local` provider's `models` list also claims the haiku ids
(`claude-3-5-haiku-20241022`, `claude-haiku-4-5`,
`claude-haiku-4-5-20251001`), so any haiku-tagged request from CC (the
default model selection, the subagent model, etc.) is automatically routed
to the local Qwen 7B.

### Cost knobs

- **Make most things free**: change `default` to `local,qwen2.5-coder-7b`
  and drop `longContextThreshold` to ~30000. Lower quality, near-zero API
  spend. Latency depends entirely on the prefill cost of CC's ~28 K-token
  system prompt; with `--cache-reuse` and the attribution-header flag set,
  steady-state is acceptable.
- **Custom router**: point `CUSTOM_ROUTER_PATH` at a JS module that inspects
  the request and decides per-prompt. Best cost/quality ratio.

### Custom transformers

`~/.claude-code-router/plugins/strip-billing-header.js` is registered as a
transformer on the `local` provider. It filters any system block whose
text starts with `x-anthropic-billing-header:` (both Anthropic-shaped
`system: [...]` and OpenAI-shaped `messages: [{role:"system"}]`). The
client-side `CLAUDE_CODE_ATTRIBUTION_HEADER=0` flag does the same job from
the source; the plugin remains as a fallback in case a client forgets the
flag or runs an older CC version. Add new transformers as JS files in
`~/.claude-code-router/plugins/` and register them in the `transformers`
array in `config.json`.

---

## Post-install changes

The installer (`my-ia-setup-install.sh`) currently only ships the legacy
14B Instruct + Gemma stack and a vanilla `llama-swap` config. The host has
since been moved to the architecture documented here. If you re-run the
installer on a fresh machine, you'll need to re-apply these steps to reach
parity:

### 1. Download additional models

```bash
cd ~/.models

# Qwen 2.5 Coder 7B — default for Claude Code (GPU)
curl -L --fail -o Qwen2.5-Coder-7B-Instruct-Q4_K_M.gguf \
  "https://huggingface.co/bartowski/Qwen2.5-Coder-7B-Instruct-GGUF/resolve/main/Qwen2.5-Coder-7B-Instruct-Q4_K_M.gguf?download=true"

# DeepSeek-R1-Distill-Qwen 7B — reasoning model on CPU
curl -L --fail -o DeepSeek-R1-Distill-Qwen-7B-Q4_K_M.gguf \
  "https://huggingface.co/bartowski/DeepSeek-R1-Distill-Qwen-7B-GGUF/resolve/main/DeepSeek-R1-Distill-Qwen-7B-Q4_K_M.gguf?download=true"
```

### 2. Update `~/.config/llama-swap/config.yaml`

Three things to get right at once: which models are always loaded, which one
is opt-in and evicts the rest, and which one runs on CPU. The shape:

```yaml
healthCheckTimeout: 120

models:
  qwen2.5-coder-7b:
    aliases: [qwen-coder, qwen2.5-7b-coder]
    cmd: |
      llama-server -m /home/alex/.models/Qwen2.5-Coder-7B-Instruct-Q4_K_M.gguf
        --ctx-size 65536
        --parallel 1
        --cache-reuse 256
        --n-gpu-layers 99
        --jinja
        --host 127.0.0.1
        --port ${PORT}
    ttl: 0   # always loaded; preloaded at startup

  qwen2.5-14b-coder:
    aliases: [qwen2.5-14b]
    cmd: |
      llama-server -m /home/alex/.models/Qwen2.5-14B-Instruct-Q4_K_M.gguf
        --ctx-size 65536
        --parallel 1
        --cache-reuse 256
        --n-gpu-layers 99
        --cache-type-k q8_0 --cache-type-v q8_0 --flash-attn on
        --jinja
        --host 127.0.0.1
        --port ${PORT}
    ttl: 600   # opt-in; unload after 10 min idle

  gemma-3-4b-familiar:
    aliases: [gemma-3-4b]
    cmd: |
      llama-server -m /home/alex/.models/google_gemma-3-4b-it-Q5_K_M.gguf
        --mmproj /home/alex/.models/mmproj-google_gemma-3-4b-it-f16.gguf
        --ctx-size 8192
        --n-gpu-layers 99
        --jinja
        --host 127.0.0.1
        --port ${PORT}
    ttl: 0   # always loaded; preloaded at startup

  deepseek-r1-distill-7b:
    aliases: [r1-7b, deepseek-r1-7b]
    env: ["CUDA_VISIBLE_DEVICES="]
    cmd: |
      llama-server -m /home/alex/.models/DeepSeek-R1-Distill-Qwen-7B-Q4_K_M.gguf
        --ctx-size 16384
        --n-gpu-layers 0
        --threads 12
        --threads-batch 16
        --jinja
        --host 127.0.0.1
        --port ${PORT}
    ttl: 0   # always loaded; preloaded at startup

groups:
  # Always-on GPU pair. swap=false → both stay resident together.
  # Combined VRAM on the P100: ~13.5 GB (8.6 + ~4.9), ~2.5 GB headroom.
  # Non-persistent so the heavy group can evict on demand.
  gpu:
    swap: false
    exclusive: false
    members: [qwen2.5-coder-7b, gemma-3-4b-familiar]

  # Opt-in heavy GPU model. exclusive=true → evicts non-persistent groups
  # (the gpu pair). The cpu group is persistent and survives.
  gpu-heavy:
    swap: true
    exclusive: true
    members: [qwen2.5-14b-coder]

  # CPU-only group, always resident. persistent=true protects it from
  # being unloaded when gpu-heavy is requested.
  cpu:
    swap: false
    exclusive: false
    persistent: true
    members: [deepseek-r1-distill-7b]

# Preload at startup so the first request after reboot is warm.
# Members of the gpu group must coexist (swap=false) for multi-preload to
# work; otherwise llama-swap would just swap them in and out during boot.
hooks:
  on_startup:
    preload:
      - qwen2.5-coder-7b
      - gemma-3-4b-familiar
      - deepseek-r1-distill-7b
```

Notes:

- The 7B Coder is intentionally configured **without** `--flash-attn` and
  with `f16` KV cache. On Pascal these flags hurt; on Ampere+ you'd want
  to enable them.
- `--cache-reuse 256` only pays off when the prompt prefix is byte-stable;
  see the client-side `CLAUDE_CODE_ATTRIBUTION_HEADER` flag below.
- `CUDA_VISIBLE_DEVICES=""` is essential for the CPU model — even with
  `--n-gpu-layers 0`, a CUDA-built `llama-server` still tries to allocate
  ~1 GB on GPU 0 and segfaults if the GPU is full.
- After `qwen2.5-14b-coder` is requested, the gpu pair stays unloaded
  until the 14B's TTL expires (10 min idle) and the next request triggers
  reload. There is no automatic "go back to preload state" — restart
  `llama-swap` to force it. Requesting a member of the (non-exclusive)
  gpu group while the 14B is resident does **not** evict the 14B; the
  request will OOM and 502 because only `exclusive: true` triggers
  cross-group unloads.

Then `sudo systemctl restart llama-swap`. After ~25 s the three preloaded
models should all show as `ready` in `curl -sS http://localhost:8001/running`.

### 3. Update `~/.claude-code-router/config.json`

Three changes:

1. Set `Router.background` to `local,qwen2.5-coder-7b` (was 14B).
2. Add `qwen2.5-coder-7b` and `deepseek-r1-distill-7b` to the `local`
   provider's `models` list.
3. Register the local provider's `transformer.use` to include
   `strip-billing-header`, and add the plugin path under top-level
   `transformers`:

```json
"transformers": [
  { "path": "/home/alex/.claude-code-router/plugins/strip-billing-header.js" }
]
```

4. Drop the plugin file at
   `~/.claude-code-router/plugins/strip-billing-header.js` (see the file
   in this repo's `plugins/` directory for the canonical implementation).

5. Set `LOG: true` in the same config to enable per-turn logs in
   `~/.claude-code-router/logs/`.

Then `sudo systemctl restart ccr`.

### 3a. Install the systemd drop-ins for the persistence daemon

Required on any host that uses the `nvidia-driver-535` package (Ubuntu 24.04 default), even if there's only one GPU. See [GPU layout & nvidia-persistenced](#gpu-layout--nvidia-persistenced) for the full reasoning.

```bash
sudo install -d /etc/systemd/system/nvidia-persistenced.service.d
sudo tee /etc/systemd/system/nvidia-persistenced.service.d/override.conf >/dev/null <<'EOF'
[Unit]
StopWhenUnneeded=false

[Service]
ExecStart=
ExecStart=/usr/bin/nvidia-persistenced --user nvidia-persistenced --verbose
EOF

sudo install -d /etc/systemd/system/llama-swap.service.d
sudo tee /etc/systemd/system/llama-swap.service.d/nvidia-persistenced.conf >/dev/null <<'EOF'
[Unit]
Wants=nvidia-persistenced.service
After=nvidia-persistenced.service
EOF

sudo systemctl daemon-reload
sudo systemctl restart llama-swap
```

### 4. Set Claude Code's `settings.json` on the client

See [§ Client setup — step 3](#3-configure-claude-code-via-settingsjson-preferred).
Without `CLAUDE_CODE_ATTRIBUTION_HEADER=0` in the client, the local-model
path will still work but every turn will pay a full ~70 s prefill instead
of 1–3 s.

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

## GPU layout & nvidia-persistenced

The host has two NVIDIA GPUs at different PCI addresses, each on a different driver. The split is intentional and load-bearing:

| PCI bus | GPU | Driver | Used by |
| --- | --- | --- | --- |
| `03:00.0` | Tesla P100 16 GB | `nvidia` 535.x (proprietary) | CUDA → `llama-server` |
| `04:00.0` | GeForce GT 730 | `nouveau` | local desktop (gdm/Xorg) |

The 535 driver explicitly refuses Kepler (`NVRM: ... will ignore this GPU`), which is the desired outcome — `nouveau` drives the GT 730 for the desktop, and `nvidia` only ever talks to the P100. `prime-select` is set to `on-demand`. **Avoid switching to `prime-select nvidia` or installing the 470 legacy driver** to "support" the GT 730 — both break CUDA on the P100, and inference silently falls back to CPU (~7 t/s instead of ~40 t/s) without any error in `nvidia-smi`.

### The persistence daemon is required

Ubuntu's `nvidia-persistenced.service` (shipped by `nvidia-driver-535`) is configured for a laptop Optimus profile, not a server:

- `StopWhenUnneeded=true` → systemd kills the daemon ~1 s after start unless something `Wants=` it
- `--no-persistence-mode` → even if it stays up, it does nothing

Without a running persistence daemon, the kernel module unloads whenever no process holds a handle, and the next `cuInit()` from `llama-server` races against the unload and fails with `unknown error` (CUDA error 999). Two systemd drop-ins fix this and are part of the deployed configuration:

```ini
# /etc/systemd/system/nvidia-persistenced.service.d/override.conf
[Unit]
StopWhenUnneeded=false

[Service]
ExecStart=
ExecStart=/usr/bin/nvidia-persistenced --user nvidia-persistenced --verbose
```

```ini
# /etc/systemd/system/llama-swap.service.d/nvidia-persistenced.conf
[Unit]
Wants=nvidia-persistenced.service
After=nvidia-persistenced.service
```

After dropping these files in:

```bash
sudo systemctl daemon-reload
sudo systemctl restart llama-swap
```

`llama-swap` now pulls `nvidia-persistenced` up on start, the daemon keeps four handles open on `/dev/nvidia0`, and `cuInit()` succeeds reliably. To verify:

```bash
systemctl is-active nvidia-persistenced llama-swap ccr
nvidia-smi --query-gpu=persistence_mode,memory.used --format=csv,noheader
# After a request that loads qwen2.5-coder-7b: Enabled, ~8598 MiB
```

### Module parameter hygiene

Files in `/etc/modprobe.d/` only need three NVIDIA-related entries:

| File | Purpose |
| --- | --- |
| `nvidia-graphics-drivers-kms.conf` | shipped by `nvidia-driver-535`; sets `nvidia-drm modeset=0` |
| `gt730-fix.conf` | local; sets `nouveau modeset=1` so the GT 730 drives the desktop |
| `blacklist-framebuffer.conf` | Ubuntu default; do not touch |

Anything else (typically `NVreg_*` knobs added during troubleshooting) is suspect — the 535 driver silently ignores any parameter it doesn't recognise. To check for leftover noise:

```bash
sudo dmesg | grep -i 'unknown parameter'
```

A clean boot should show no NVRM `unknown parameter` lines.

### Local desktop on the GT 730 (Xorg pin)

Xorg auto-config orders devices by PCI bus, so the P100 (`03:00.0`) is picked first. With `nvidia-drm modeset=0` (set by Ubuntu's `nvidia-graphics-drivers-kms.conf`) the P100 has no KMS, so Xorg dies with `(EE) [drm] Failed to open DRM device for (null): -2` / `no screens found` and gdm loops on `GdmDisplay: Session never registered, failing`. Two pieces are needed:

1. **`gdm` user must be in the `video` and `render` groups** so Xorg launched by gdm can open `/dev/fb0`, `/dev/dri/card0`, and `/dev/dri/renderD128` (all `root:video` / `root:render`):

   ```bash
   sudo usermod -aG video,render gdm
   ```

2. **Pin Xorg to the GT 730** with a `modesetting` (KMS) device so it ignores the P100, and **force a non-SCDC HDMI mode** (1920x1080@60Hz) so it stays within HDMI 1.4 limits — the GT 730 is Kepler GK208B with HDMI 1.4 only (max ~340 MHz pixel clock). With a 4K display attached, the EDID's preferred mode is 3840x2160@60Hz at 533 MHz, which requires HDMI 2.0 / SCDC; nouveau tries it, the SCDC handshake fails (`Failure to read SCDC_TMDS_CONFIG: -6`, kmsOutp `ret:-22`), and the screen stays black even though Xorg/gdm consider the modeset successful. Drop in `/etc/X11/xorg.conf.d/10-gt730-only.conf`:

   ```
   Section "Device"
       Identifier "GT730"
       Driver     "modesetting"
       BusID      "PCI:4:0:0"
       Option     "kmsdev" "/dev/dri/card0"
   EndSection

   Section "Monitor"
       Identifier "HDMI-1"
       Option     "PreferredMode" "1920x1080"
   EndSection

   Section "Screen"
       Identifier "Screen0"
       Device     "GT730"
       Monitor    "HDMI-1"
       DefaultDepth 24
       SubSection "Display"
           Depth 24
           Modes "1920x1080"
       EndSubSection
   EndSection

   Section "ServerLayout"
       Identifier "Layout0"
       Screen 0  "Screen0"
   EndSection
   ```

   Use `Driver "modesetting"`, **not** the legacy UMS `nouveau` Xorg driver — the latter fails with `xf86EnableIO: failed to enable I/O ports 0000-03ff (Operation not permitted)` under the unprivileged Xorg wrapper. If `/usr/share/X11/xorg.conf.d/20-gt730.conf` exists from a previous attempt with `Driver "nouveau"` and no `Screen` section, rename it to `.disabled` — it will conflict. If you swap in a 1080p monitor (or a 4K one over DVI/VGA, both bandwidth-capped on this card), the Monitor + Modes lines are still safe; raise the cap only if you replace the GT 730 with an HDMI 2.0 card.

After both: `sudo systemctl restart gdm` and the greeter should appear on the monitor connected to the GT 730. Verify with:

```bash
ps -eo user,comm | grep -E 'Xorg|gnome-shell'   # expect Xorg + gnome-shell under user gdm
loginctl list-sessions                          # expect a seat0/tty1 session for user gdm
```

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
| `~/.claude-code-router/plugins/`              | Custom transformer plugins (e.g. `strip-billing-header.js`) |
| `~/.claude-code-router/logs/ccr-*.log`        | Per-launch ccr logs (rotates on restart)           |
| `~/.config/llama-swap/config.yaml`            | Per-model cmd + aliases + ttl + groups             |
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
├── my-ia-setup-install.sh           # The base installer. ~900 lines, idempotent.
├── plugins/
│   └── strip-billing-header.js      # ccr transformer (cached fallback for the billing header bug)
├── CLAUDE.md                        # Working notes for Claude Code agents.
├── INVENTORY.md                     # Snapshot of the live host (hardware, drivers, Xorg, units, ports).
├── README.md                        # This file.
└── .gitignore
```

The installer is intentionally a single self-contained file; it generates
the entire `~/ai-setup-docs/` tree on the target host so the deployed copy
is the source of truth at runtime.

`INVENTORY.md` is a snapshot of the deployed state (kernel cmdline, modprobe
files, udev rules, Xorg snippets, systemd unit drop-ins, listening ports,
`~/.models/` contents). Refresh it when the host materially changes — it is
the disaster-recovery reference, complementing the configuration *intent*
documented in this README and `CLAUDE.md`.

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
| Local model answers but is suddenly slow (~7 t/s instead of ~40), `nvidia-smi` shows GPU at `0 MiB / 0 %` while inference runs | `nvidia-persistenced` is dead. CUDA fell back to CPU silently. Check `systemctl is-active nvidia-persistenced` and `nvidia-smi --query-gpu=persistence_mode --format=csv`. See [GPU layout & nvidia-persistenced](#gpu-layout--nvidia-persistenced). |
| `dmesg` shows a tight `nvidia-modeset: Unloading / Loading` loop while CUDA is starting | Same root cause: persistence daemon stopped, module is unloading between `cuInit()` calls. The drop-ins in the persistence section fix it. |
| `dmesg | grep 'unknown parameter'` shows `NVreg_*` lines | Stale `/etc/modprobe.d/` files with parameters from a different driver version. Safe to remove (back them up to `/var/backups/` first). |

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
