#!/usr/bin/env bash
#
# my-ia-setup-install.sh — full bare-metal install of the hybrid AI stack on
# Ubuntu 24.04 with an NVIDIA Pascal GPU (e.g. P100). Idempotent: each step
# checks first whether the right thing is already in place and skips if so.
#
# Run as the target user (default: $USER), not as root.
#
#   ANTHROPIC_API_KEY=sk-ant-... ./my-ia-setup-install.sh
#
# Optional environment variables:
#   TARGET_USER          user that owns the stack          (default: $USER)
#   ANTHROPIC_API_KEY    Anthropic key. Prompt if unset.
#   CCR_APIKEY           token shared with Claude Code clients. Generated if unset.
#   LLAMA_SWAP_VERSION   pinned llama-swap release         (default: v210)
#   LLAMA_SWAP_SHA256    expected sha256 for the pinned tarball
#   CUDA_ARCH            CUDA arch passed to llama.cpp     (default: 60 for P100)
#   MIN_DRIVER_VERSION   minimum NVIDIA driver             (default: 535)
#   MIN_VRAM_GB          minimum VRAM in GB                (default: 16)
#   SKIP_MODELS=1        do not redownload GGUF files
#   SKIP_DOCKER=1        do not (re)create Open WebUI container
#   ASSUME_YES=1         do not prompt to confirm changes
#
# Outputs:
#   - Working AI stack on ports 8001 (llama-swap), 3456 (ccr), 3000 (Open WebUI)
#   - Docs and source-of-truth files under ~/ai-setup-docs/
#
# What this script intentionally does NOT do:
#   - Install NVIDIA proprietary drivers (do this manually first)
#   - Touch existing models, configs, or volumes when re-running

set -euo pipefail

# ============================================================================
# Configuration
# ============================================================================
TARGET_USER="${TARGET_USER:-${USER}}"
TARGET_HOME=$(getent passwd "$TARGET_USER" | cut -d: -f6)
[[ -n "$TARGET_HOME" ]] || { echo "User $TARGET_USER not found"; exit 1; }

LLAMA_SWAP_VERSION="${LLAMA_SWAP_VERSION:-v210}"
LLAMA_SWAP_SHA256_v210="9181e9022249b556b3cc8218a705ac3fe2f2047bd9d67766ed017ffdc00cbe10"
LLAMA_SWAP_SHA256="${LLAMA_SWAP_SHA256:-}"
CUDA_ARCH="${CUDA_ARCH:-60}"
MIN_DRIVER_VERSION="${MIN_DRIVER_VERSION:-535}"
MIN_VRAM_GB="${MIN_VRAM_GB:-16}"
NODE_MAJOR="20"
DOCKER_MIN_VERSION="24"
PYTHON_MIN_VERSION="3.10"
UBUNTU_EXPECTED="24.04"

DOCS_DIR="$TARGET_HOME/ai-setup-docs"
MODELS_DIR="$TARGET_HOME/.models"
LLAMA_CPP_DIR="$TARGET_HOME/llama.cpp"

QWEN_REPO="bartowski/Qwen2.5-14B-Instruct-GGUF"
QWEN_FILE="Qwen2.5-14B-Instruct-Q4_K_M.gguf"
QWEN_MIN_BYTES=8500000000   # ~9 GB sanity floor

GEMMA_REPO="bartowski/google_gemma-3-4b-it-GGUF"
GEMMA_FILE="google_gemma-3-4b-it-Q5_K_M.gguf"
GEMMA_MIN_BYTES=2500000000
GEMMA_MMPROJ="mmproj-google_gemma-3-4b-it-f16.gguf"
GEMMA_MMPROJ_MIN_BYTES=700000000

OPEN_WEBUI_IMAGE="ghcr.io/open-webui/open-webui:main"

# ============================================================================
# Helpers
# ============================================================================
RED=$'\033[1;31m'; GREEN=$'\033[1;32m'; YELLOW=$'\033[1;33m'; BLUE=$'\033[1;34m'; DIM=$'\033[0;90m'; RESET=$'\033[0m'
ts()    { date +%H:%M:%S; }
step()  { printf '%s[%s] === %s ===%s\n' "$BLUE"   "$(ts)" "$*" "$RESET"; }
ok()    { printf '%s[%s] OK   %s%s\n'    "$GREEN"  "$(ts)" "$*" "$RESET"; }
info()  { printf '%s[%s] info %s%s\n'    "$DIM"    "$(ts)" "$*" "$RESET"; }
warn()  { printf '%s[%s] warn %s%s\n'    "$YELLOW" "$(ts)" "$*" "$RESET" >&2; }
die()   { printf '%s[%s] FAIL %s%s\n'    "$RED"    "$(ts)" "$*" "$RESET" >&2; exit 1; }

confirm() {
  [[ "${ASSUME_YES:-0}" == "1" ]] && return 0
  local prompt="$1 [y/N]: "
  local reply
  read -rp "$prompt" reply
  [[ "$reply" =~ ^[yY]$ ]]
}

version_ge() {
  # version_ge "1.2.3" "1.2.0"  → 0 (true) if first >= second
  [[ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -1)" == "$2" ]]
}

# ============================================================================
# Pre-flight
# ============================================================================
preflight() {
  step "Pre-flight checks"

  [[ "$EUID" -ne 0 ]] || die "Run as $TARGET_USER, not root."
  [[ "$USER" == "$TARGET_USER" ]] || die "Run as $TARGET_USER (currently $USER)."

  if [[ -r /etc/os-release ]]; then
    . /etc/os-release
    if [[ "${ID:-}" != "ubuntu" ]]; then
      warn "Distro is $ID (expected ubuntu). Proceeding anyway."
    elif [[ "${VERSION_ID:-}" != "$UBUNTU_EXPECTED" ]]; then
      warn "Ubuntu $VERSION_ID (expected $UBUNTU_EXPECTED). Proceeding."
    else
      ok "Ubuntu $VERSION_ID"
    fi
  fi

  if ! sudo -n true 2>/dev/null; then
    info "This script will need sudo. You may be prompted for your password."
  fi
}

# ============================================================================
# 1. NVIDIA driver + GPU
# ============================================================================
check_nvidia() {
  step "[1/13] NVIDIA driver and GPU"

  command -v nvidia-smi >/dev/null \
    || die "nvidia-smi not found. Install the proprietary NVIDIA driver first."

  local driver gpu cc vram
  driver=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader | head -1)
  gpu=$(nvidia-smi --query-gpu=name --format=csv,noheader | head -1)
  cc=$(nvidia-smi --query-gpu=compute_cap --format=csv,noheader | head -1)
  vram=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits | head -1)

  info "GPU: $gpu (compute $cc, ${vram} MiB)"
  info "Driver: $driver"

  if version_ge "$driver" "$MIN_DRIVER_VERSION"; then
    ok "Driver >= $MIN_DRIVER_VERSION"
  else
    die "NVIDIA driver $driver is older than $MIN_DRIVER_VERSION. Upgrade first."
  fi

  local cc_int="${cc%%.*}"
  if (( cc_int < 6 )); then
    die "Compute capability $cc < 6.0. CUDA arch $CUDA_ARCH won't fit."
  fi

  if (( vram < MIN_VRAM_GB * 1024 - 256 )); then
    warn "VRAM ${vram} MiB is below ${MIN_VRAM_GB} GB. Qwen14B Q4_K_M may not fit."
  fi
}

# ============================================================================
# 2. APT base packages
# ============================================================================
APT_PKGS=(
  git cmake build-essential pkg-config
  libcurl4-openssl-dev
  python3 python3-pip python3-venv
  curl wget jq openssl ca-certificates
)

ensure_apt() {
  step "[2/13] APT base packages"

  local missing=()
  for p in "${APT_PKGS[@]}"; do
    dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q '^install ok installed$' \
      || missing+=("$p")
  done

  if (( ${#missing[@]} == 0 )); then
    ok "All APT packages installed"
    return
  fi

  info "Installing: ${missing[*]}"
  sudo apt-get update -qq
  sudo apt-get install -y -qq "${missing[@]}"
  ok "Installed ${#missing[@]} APT packages"
}

# ============================================================================
# 3. CUDA toolkit
# ============================================================================
ensure_cuda() {
  step "[3/13] CUDA toolkit"

  if command -v nvcc >/dev/null; then
    local v
    v=$(nvcc --version | grep -oP 'release \K[0-9]+\.[0-9]+' | head -1)
    if [[ "$v" == "12.4" ]]; then
      ok "CUDA $v installed"
      return
    fi
    warn "CUDA $v is installed (script targets 12.4). Reusing existing toolkit."
    return
  fi

  warn "nvcc missing. Attempting to install CUDA 12.4 from default repos."
  if confirm "Install cuda-toolkit-12-4 via apt?"; then
    sudo apt-get install -y -qq cuda-toolkit-12-4 cuda-libraries-dev-12-4 \
      || die "CUDA install failed. Configure NVIDIA's CUDA repo manually."
    ok "CUDA 12.4 installed"
  else
    die "CUDA toolkit is required to build llama.cpp."
  fi
}

# ============================================================================
# 4. Python
# ============================================================================
ensure_python() {
  step "[4/13] Python $PYTHON_MIN_VERSION+"

  command -v python3 >/dev/null || die "python3 missing (apt step should have installed it)."
  local pyv
  pyv=$(python3 -c 'import sys;print(f"{sys.version_info.major}.{sys.version_info.minor}")')

  if version_ge "$pyv" "$PYTHON_MIN_VERSION"; then
    ok "Python $pyv"
  else
    die "Python $pyv < $PYTHON_MIN_VERSION required."
  fi
}

# ============================================================================
# 5. Node.js
# ============================================================================
ensure_node() {
  step "[5/13] Node.js $NODE_MAJOR.x"

  if command -v node >/dev/null; then
    local nv
    nv=$(node --version | sed 's/^v//' | cut -d. -f1)
    if [[ "$nv" == "$NODE_MAJOR" ]]; then
      ok "Node.js $(node --version)"
      return
    fi
    warn "Node $(node --version) found; replacing with $NODE_MAJOR.x"
  fi

  curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | sudo -E bash -
  sudo apt-get install -y -qq nodejs
  ok "Installed Node.js $(node --version)"
}

# ============================================================================
# 6. Docker
# ============================================================================
ensure_docker() {
  step "[6/13] Docker $DOCKER_MIN_VERSION+"

  if command -v docker >/dev/null; then
    local dv
    dv=$(docker --version | grep -oP '\d+\.\d+\.\d+' | head -1)
    if version_ge "$dv" "$DOCKER_MIN_VERSION"; then
      ok "Docker $dv"
    else
      warn "Docker $dv < $DOCKER_MIN_VERSION; you may want to upgrade."
    fi
  else
    info "Installing docker.io"
    sudo apt-get install -y -qq docker.io
    ok "Docker $(docker --version | grep -oP '\d+\.\d+\.\d+' | head -1)"
  fi

  if id -nG "$TARGET_USER" | grep -qw docker; then
    ok "$TARGET_USER is in docker group"
  else
    sudo usermod -aG docker "$TARGET_USER"
    warn "Added $TARGET_USER to docker group. Re-login or 'newgrp docker' for the change to apply."
  fi

  sudo systemctl enable --now docker >/dev/null
}

# ============================================================================
# 7. llama.cpp
# ============================================================================
ensure_llama_cpp() {
  step "[7/13] llama.cpp (CUDA arch $CUDA_ARCH)"

  if [[ ! -d "$LLAMA_CPP_DIR/.git" ]]; then
    info "Cloning ggml-org/llama.cpp"
    git clone --depth 1 https://github.com/ggml-org/llama.cpp "$LLAMA_CPP_DIR"
  fi

  cd "$LLAMA_CPP_DIR"
  git pull --ff-only --quiet
  local head_now
  head_now=$(git rev-parse --short HEAD)

  local need_build=0
  if [[ ! -x build/bin/llama-server ]]; then
    need_build=1
  else
    # Rebuild if the source has moved past the binary's timestamp.
    if [[ "$(git log -1 --format=%ct)" -gt "$(stat -c %Y build/bin/llama-server)" ]]; then
      need_build=1
    fi
  fi

  if (( need_build )); then
    info "Building (this takes a few minutes)"
    cmake -B build -DCMAKE_BUILD_TYPE=Release -DGGML_CUDA=ON -DCMAKE_CUDA_ARCHITECTURES="$CUDA_ARCH" >/dev/null
    cmake --build build --config Release -j"$(nproc)"
  else
    info "Build is fresh (HEAD $head_now)"
  fi

  sudo ln -sf "$LLAMA_CPP_DIR/build/bin/llama-server" /usr/local/bin/llama-server
  sudo ln -sf "$LLAMA_CPP_DIR/build/bin/llama-cli"    /usr/local/bin/llama-cli
  cd - >/dev/null

  /usr/local/bin/llama-server --version 2>&1 | head -1 || true
  ok "llama-server symlinked"
}

# ============================================================================
# 8. GGUF models
# ============================================================================
have_file_min_size() {
  local f=$1 min=$2
  [[ -f "$f" && $(stat -c %s "$f") -ge $min ]]
}

ensure_models() {
  step "[8/13] GGUF models"

  if [[ "${SKIP_MODELS:-0}" == "1" ]]; then
    info "SKIP_MODELS=1; not touching $MODELS_DIR"
    return
  fi

  mkdir -p "$MODELS_DIR"

  if ! command -v hf >/dev/null 2>&1; then
    info "Installing huggingface_hub + hf_transfer"
    pip install --quiet --break-system-packages huggingface_hub hf_transfer
  fi
  export HF_HUB_ENABLE_HF_TRANSFER=1

  if have_file_min_size "$MODELS_DIR/$QWEN_FILE" "$QWEN_MIN_BYTES"; then
    ok "$QWEN_FILE present"
  else
    info "Downloading $QWEN_FILE (~9 GB)"
    hf download "$QWEN_REPO" --include "*Q4_K_M*" --local-dir "$MODELS_DIR/"
    have_file_min_size "$MODELS_DIR/$QWEN_FILE" "$QWEN_MIN_BYTES" \
      || die "$QWEN_FILE download incomplete"
    ok "$QWEN_FILE downloaded"
  fi

  if have_file_min_size "$MODELS_DIR/$GEMMA_FILE" "$GEMMA_MIN_BYTES" && \
     have_file_min_size "$MODELS_DIR/$GEMMA_MMPROJ" "$GEMMA_MMPROJ_MIN_BYTES"; then
    ok "$GEMMA_FILE + $GEMMA_MMPROJ present"
  else
    info "Downloading $GEMMA_FILE + mmproj (~3.6 GB)"
    hf download "$GEMMA_REPO" --include "*Q5_K_M*" --include "mmproj*f16*" \
      --local-dir "$MODELS_DIR/"
    have_file_min_size "$MODELS_DIR/$GEMMA_FILE" "$GEMMA_MIN_BYTES" \
      || die "$GEMMA_FILE download incomplete"
    ok "Gemma model + mmproj downloaded"
  fi
}

# ============================================================================
# 9. claude-code-router
# ============================================================================
ensure_ccr() {
  step "[9/13] claude-code-router"

  if command -v ccr >/dev/null; then
    local v
    v=$(ccr -v 2>&1 | grep -oP '\d+\.\d+\.\d+' | head -1 || true)
    info "ccr present (version: ${v:-unknown})"
    ok "ccr binary at $(command -v ccr)"
    return
  fi

  info "Installing @musistudio/claude-code-router globally"
  sudo npm install -g --silent @musistudio/claude-code-router
  ok "ccr installed: $(command -v ccr)"
}

# ============================================================================
# 10. llama-swap
# ============================================================================
ensure_llama_swap() {
  step "[10/13] llama-swap $LLAMA_SWAP_VERSION"

  local target_num="${LLAMA_SWAP_VERSION#v}"
  if command -v llama-swap >/dev/null; then
    local v
    v=$(llama-swap --version 2>&1 | grep -oP 'version: \K\d+' | head -1 || true)
    if [[ "$v" == "$target_num" ]]; then
      ok "llama-swap $LLAMA_SWAP_VERSION already installed"
      return
    fi
    info "llama-swap version $v differs from target $target_num; replacing"
  fi

  local sha_var="LLAMA_SWAP_SHA256_${LLAMA_SWAP_VERSION}"
  local expected_sha="${LLAMA_SWAP_SHA256:-${!sha_var:-}}"
  if [[ -z "$expected_sha" ]]; then
    warn "No SHA256 pinned for $LLAMA_SWAP_VERSION; downloading without checksum verification."
  fi

  local tgz="llama-swap_${target_num}_linux_amd64.tar.gz"
  local url="https://github.com/mostlygeek/llama-swap/releases/download/${LLAMA_SWAP_VERSION}/${tgz}"
  local tmp
  tmp=$(mktemp -d)
  trap "rm -rf '$tmp'" RETURN
  info "Downloading $tgz"
  curl -fsSL --max-time 180 -o "$tmp/$tgz" "$url"
  if [[ -n "$expected_sha" ]]; then
    local actual_sha
    actual_sha=$(sha256sum "$tmp/$tgz" | awk '{print $1}')
    [[ "$actual_sha" == "$expected_sha" ]] \
      || die "llama-swap SHA256 mismatch (got $actual_sha, expected $expected_sha)"
    ok "SHA256 verified"
  fi
  tar xzf "$tmp/$tgz" -C "$tmp"
  sudo install -m 0755 "$tmp/llama-swap" /usr/local/bin/llama-swap
  ok "Installed $(llama-swap --version 2>&1 | head -1)"
}

# ============================================================================
# 11. Configs (ccr + llama-swap)  ─── secrets handled with care
# ============================================================================
collect_secrets() {
  if [[ -z "${ANTHROPIC_API_KEY:-}" ]]; then
    if [[ -f "$TARGET_HOME/.claude-code-router/config.json" ]]; then
      info "Reusing existing ANTHROPIC_API_KEY from current ccr config"
      ANTHROPIC_API_KEY=$(jq -r '.Providers[]|select(.name=="anthropic")|.api_key' \
        "$TARGET_HOME/.claude-code-router/config.json" 2>/dev/null || true)
    fi
  fi
  if [[ -z "${ANTHROPIC_API_KEY:-}" || ! "$ANTHROPIC_API_KEY" =~ ^sk-ant- ]]; then
    read -rsp "Anthropic API key (sk-ant-...): " ANTHROPIC_API_KEY
    echo
    [[ "$ANTHROPIC_API_KEY" =~ ^sk-ant- ]] || die "Invalid key format"
  fi

  if [[ -z "${CCR_APIKEY:-}" ]]; then
    if [[ -f "$TARGET_HOME/.claude-code-router/config.json" ]]; then
      CCR_APIKEY=$(jq -r '.APIKEY' "$TARGET_HOME/.claude-code-router/config.json" 2>/dev/null || true)
    fi
  fi
  if [[ -z "${CCR_APIKEY:-}" || "$CCR_APIKEY" == "null" ]]; then
    CCR_APIKEY="sk-llama-cpp-$(openssl rand -hex 12)"
    info "Generated new CCR APIKEY: $CCR_APIKEY"
    info "  This is what Windows Claude Code clients send as ANTHROPIC_AUTH_TOKEN."
  fi
}

ensure_configs() {
  step "[11/13] Configs"

  collect_secrets

  # ccr
  mkdir -p "$TARGET_HOME/.claude-code-router"
  chmod 0700 "$TARGET_HOME/.claude-code-router"
  local ccr_cfg="$TARGET_HOME/.claude-code-router/config.json"
  [[ -f "$ccr_cfg" ]] && cp -p "$ccr_cfg" "$ccr_cfg.bak.$(date +%s)"
  umask 077
  cat >"$ccr_cfg" <<EOF
{
  "LOG": false,
  "LOG_LEVEL": "debug",
  "HOST": "0.0.0.0",
  "PORT": 3456,
  "APIKEY": "$CCR_APIKEY",
  "API_TIMEOUT_MS": "600000",
  "Providers": [
    {
      "name": "local",
      "api_base_url": "http://localhost:8001/v1/chat/completions",
      "api_key": "local",
      "models": ["qwen2.5-14b"]
    },
    {
      "name": "anthropic",
      "api_base_url": "https://api.anthropic.com/v1/messages",
      "api_key": "$ANTHROPIC_API_KEY",
      "models": ["claude-opus-4-7", "claude-sonnet-4-6"],
      "transformer": { "use": ["Anthropic"] }
    }
  ],
  "Router": {
    "default": "anthropic,claude-sonnet-4-6",
    "background": "local,qwen2.5-14b",
    "think": "anthropic,claude-opus-4-7",
    "longContext": "anthropic,claude-opus-4-7",
    "longContextThreshold": 60000
  }
}
EOF
  umask 022
  chmod 0600 "$ccr_cfg"
  ok "ccr config written ($ccr_cfg, mode 0600)"

  # llama-swap
  mkdir -p "$TARGET_HOME/.config/llama-swap"
  cat >"$TARGET_HOME/.config/llama-swap/config.yaml" <<EOF
healthCheckTimeout: 120

models:
  qwen2.5-14b-coder:
    aliases:
      - qwen2.5-14b
    cmd: |
      llama-server -m $MODELS_DIR/$QWEN_FILE
        --ctx-size 32768 --n-gpu-layers 99
        --cache-type-k q8_0 --cache-type-v q8_0
        --flash-attn on --jinja
        --host 127.0.0.1 --port \${PORT}
    ttl: 600

  gemma-3-4b-familiar:
    aliases:
      - gemma-3-4b
    cmd: |
      llama-server -m $MODELS_DIR/$GEMMA_FILE
        --mmproj $MODELS_DIR/$GEMMA_MMPROJ
        --ctx-size 8192 --n-gpu-layers 99
        --flash-attn on --jinja
        --host 127.0.0.1 --port \${PORT}
    ttl: 600
EOF
  ok "llama-swap config written"
}

# ============================================================================
# 12. systemd, scripts, sudoers
# ============================================================================
write_systemd_and_scripts() {
  mkdir -p "$DOCS_DIR/systemd" "$DOCS_DIR/scripts" "$DOCS_DIR/sudoers.d" \
           "$DOCS_DIR/profiles" "$DOCS_DIR/config-proposals" "$DOCS_DIR/backups"

  cat >"$DOCS_DIR/systemd/llama-swap.service" <<EOF
[Unit]
Description=llama-swap proxy on :8001
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$TARGET_USER
Group=$TARGET_USER
WorkingDirectory=$TARGET_HOME
Environment=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
ExecStart=/usr/local/bin/llama-swap -config $TARGET_HOME/.config/llama-swap/config.yaml -listen 0.0.0.0:8001
Restart=on-failure
RestartSec=5s
TimeoutStartSec=180
TimeoutStopSec=30
StandardOutput=journal
StandardError=journal
SyslogIdentifier=llama-swap
NoNewPrivileges=true
PrivateTmp=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictSUIDSGID=true
LockPersonality=true

[Install]
WantedBy=multi-user.target
EOF

  cat >"$DOCS_DIR/systemd/ccr.service" <<EOF
[Unit]
Description=Claude Code Router on :3456
After=network-online.target llama-swap.service
Wants=network-online.target llama-swap.service

[Service]
Type=simple
User=$TARGET_USER
Group=$TARGET_USER
WorkingDirectory=$TARGET_HOME
Environment=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
Environment=NODE_ENV=production
ExecStart=/usr/local/bin/ccr start
Restart=on-failure
RestartSec=5s
TimeoutStartSec=30
TimeoutStopSec=15
StandardOutput=journal
StandardError=journal
SyslogIdentifier=ccr
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF

  cat >"$DOCS_DIR/scripts/healthcheck.sh" <<'EOF'
#!/bin/bash
set -u
LLAMA_URL="http://127.0.0.1:8001/v1/models"
CCR_URL="http://127.0.0.1:3456/"
WEBUI_URL="http://127.0.0.1:3000/health"
TIMEOUT=5
failures=()
check() {
  local n=$1 u=$2 e=$3 c
  c=$(curl -s -o /dev/null -w '%{http_code}' --max-time "$TIMEOUT" "$u" || echo 000)
  [[ "$c" == "$e" ]] || failures+=("$n (HTTP $c, expected $e at $u)")
}
check "llama-swap" "$LLAMA_URL" "200"
check "ccr"        "$CCR_URL"   "200"
check "open-webui" "$WEBUI_URL" "200"
if (( ${#failures[@]} == 0 )); then echo "OK: all services healthy"; exit 0; fi
echo "AI stack DEGRADED: ${failures[*]}" >&2
[[ -n "${NTFY_TOPIC:-}" ]] && curl -fsS --max-time 5 \
  -H "Title: AI server alert" -H "Priority: high" -H "Tags: warning" \
  -d "AI stack DEGRADED: ${failures[*]}" \
  "https://ntfy.sh/${NTFY_TOPIC}" >/dev/null || true
exit 1
EOF
  chmod +x "$DOCS_DIR/scripts/healthcheck.sh"

  cat >"$DOCS_DIR/scripts/backup.sh" <<EOF
#!/bin/bash
set -euo pipefail
DEST_ROOT="$TARGET_HOME/backups/ai-setup"
TODAY="\$(date +%Y-%m-%d)"
DEST="\$DEST_ROOT/\$TODAY"
RETAIN=14
mkdir -p "\$DEST"
[[ -d "$TARGET_HOME/.claude-code-router" ]] && \\
  tar czf "\$DEST/claude-code-router.tar.gz" -C "$TARGET_HOME" .claude-code-router \\
    --exclude='.claude-code-router/logs' --exclude='.claude-code-router/.claude-code-router.pid'
[[ -d "$TARGET_HOME/.config/llama-swap" ]] && \\
  tar czf "\$DEST/llama-swap.tar.gz" -C "$TARGET_HOME/.config" llama-swap
for u in llama-swap.service ccr.service ai-healthcheck.service ai-healthcheck.timer ai-backup.service ai-backup.timer; do
  [[ -r "/etc/systemd/system/\$u" ]] && install -m 0644 "/etc/systemd/system/\$u" "\$DEST/\$u"
done
if docker volume inspect open-webui >/dev/null 2>&1; then
  docker run --rm -v open-webui:/data:ro -v "\$DEST":/backup alpine \\
    tar czf /backup/open-webui-volume.tar.gz -C /data . >/dev/null
fi
chmod 0700 "\$DEST"
cd "\$DEST_ROOT"
mapfile -t old < <(ls -1 | sort | head -n -"\$RETAIN")
for d in "\${old[@]:-}"; do [[ -n "\$d" && -d "\$d" ]] && rm -rf -- "\$d"; done
echo "Backup complete: \$DEST"
EOF
  chmod +x "$DOCS_DIR/scripts/backup.sh"

  cat >"$DOCS_DIR/scripts/update-stack.sh" <<EOF
#!/bin/bash
set -euo pipefail
LLAMA_DIR="$LLAMA_CPP_DIR"
log() { echo "[\$(date +%H:%M:%S)] \$*"; }
log "Updating llama.cpp"
cd "\$LLAMA_DIR"
b=\$(git rev-parse HEAD); git pull --ff-only; a=\$(git rev-parse HEAD)
if [[ "\$b" != "\$a" ]]; then
  cmake -B build -DCMAKE_BUILD_TYPE=Release -DGGML_CUDA=ON -DCMAKE_CUDA_ARCHITECTURES=$CUDA_ARCH >/dev/null
  cmake --build build --config Release -j"\$(nproc)"
  sudo systemctl restart llama-swap.service
fi
log "Updating ccr"
cb=\$(npm ls -g @musistudio/claude-code-router --depth=0 2>/dev/null | awk -F@ '/claude-code-router/{print \$NF}' | tr -d '\n')
sudo npm update -g @musistudio/claude-code-router
ca=\$(npm ls -g @musistudio/claude-code-router --depth=0 2>/dev/null | awk -F@ '/claude-code-router/{print \$NF}' | tr -d '\n')
[[ "\$cb" != "\$ca" ]] && sudo systemctl restart ccr.service
log "Updating open-webui"
docker pull $OPEN_WEBUI_IMAGE >/dev/null
docker stop open-webui 2>/dev/null || true
docker rm   open-webui 2>/dev/null || true
docker run -d --name open-webui --restart always --network host \\
  -v open-webui:/app/backend/data $OPEN_WEBUI_IMAGE
log "Update complete"
EOF
  chmod +x "$DOCS_DIR/scripts/update-stack.sh"

  cat >"$DOCS_DIR/systemd/ai-healthcheck.service" <<EOF
[Unit]
Description=AI stack healthcheck (driven by ai-healthcheck.timer)
After=network-online.target

[Service]
Type=oneshot
User=$TARGET_USER
Group=$TARGET_USER
# Environment=NTFY_TOPIC=your-secret-topic
ExecStart=$DOCS_DIR/scripts/healthcheck.sh
SyslogIdentifier=ai-healthcheck
EOF

  cat >"$DOCS_DIR/systemd/ai-healthcheck.timer" <<'EOF'
[Unit]
Description=Run AI stack healthcheck every 5 minutes
[Timer]
OnBootSec=2min
OnUnitActiveSec=5min
AccuracySec=30s
Unit=ai-healthcheck.service
[Install]
WantedBy=timers.target
EOF

  cat >"$DOCS_DIR/systemd/ai-backup.service" <<EOF
[Unit]
Description=AI stack daily backup (driven by ai-backup.timer)
After=network-online.target docker.service
Wants=docker.service

[Service]
Type=oneshot
User=$TARGET_USER
Group=$TARGET_USER
ExecStart=$DOCS_DIR/scripts/backup.sh
SyslogIdentifier=ai-backup
EOF

  cat >"$DOCS_DIR/systemd/ai-backup.timer" <<'EOF'
[Unit]
Description=Run AI stack backup daily at 03:00
[Timer]
OnCalendar=*-*-* 03:00:00
Persistent=true
RandomizedDelaySec=10min
Unit=ai-backup.service
[Install]
WantedBy=timers.target
EOF

  cat >"$DOCS_DIR/sudoers.d/ai-stack" <<EOF
Cmnd_Alias AI_STACK_UNITS = \\
    /usr/bin/systemctl start   llama-swap.service, \\
    /usr/bin/systemctl stop    llama-swap.service, \\
    /usr/bin/systemctl restart llama-swap.service, \\
    /usr/bin/systemctl reload  llama-swap.service, \\
    /usr/bin/systemctl start   ccr.service, \\
    /usr/bin/systemctl stop    ccr.service, \\
    /usr/bin/systemctl restart ccr.service, \\
    /usr/bin/systemctl reload  ccr.service, \\
    /usr/bin/systemctl start   ai-healthcheck.timer, \\
    /usr/bin/systemctl stop    ai-healthcheck.timer, \\
    /usr/bin/systemctl restart ai-healthcheck.timer, \\
    /usr/bin/systemctl start   ai-backup.timer, \\
    /usr/bin/systemctl stop    ai-backup.timer, \\
    /usr/bin/systemctl restart ai-backup.timer, \\
    /usr/bin/systemctl daemon-reload
$TARGET_USER ALL=(root) NOPASSWD: AI_STACK_UNITS
EOF
}

ensure_systemd() {
  step "[12/13] Systemd units, scripts, sudoers"

  write_systemd_and_scripts

  local need_reload=0
  for u in llama-swap.service ccr.service ai-healthcheck.service ai-healthcheck.timer \
           ai-backup.service ai-backup.timer; do
    if ! cmp -s "$DOCS_DIR/systemd/$u" "/etc/systemd/system/$u" 2>/dev/null; then
      sudo install -m 0644 "$DOCS_DIR/systemd/$u" "/etc/systemd/system/$u"
      info "Installed $u"
      need_reload=1
    fi
  done

  if ! sudo cmp -s "$DOCS_DIR/sudoers.d/ai-stack" /etc/sudoers.d/ai-stack 2>/dev/null; then
    sudo visudo -cf "$DOCS_DIR/sudoers.d/ai-stack" >/dev/null
    sudo install -m 0440 "$DOCS_DIR/sudoers.d/ai-stack" /etc/sudoers.d/ai-stack
    ok "Sudoers dropin installed"
  else
    ok "Sudoers dropin already up to date"
  fi

  (( need_reload )) && sudo systemctl daemon-reload
  sudo systemctl enable --now llama-swap.service     >/dev/null
  sudo systemctl enable --now ccr.service            >/dev/null
  sudo systemctl enable --now ai-healthcheck.timer   >/dev/null
  sudo systemctl enable --now ai-backup.timer        >/dev/null
  ok "All units enabled and running"
}

# ============================================================================
# 13. Open WebUI
# ============================================================================
ensure_open_webui() {
  step "[13/13] Open WebUI ($OPEN_WEBUI_IMAGE)"

  if [[ "${SKIP_DOCKER:-0}" == "1" ]]; then
    info "SKIP_DOCKER=1; skipping container management"
    return
  fi

  if docker ps --format '{{.Names}}' | grep -q '^open-webui$'; then
    ok "open-webui container running"
    return
  fi

  if docker ps -a --format '{{.Names}}' | grep -q '^open-webui$'; then
    info "Starting existing open-webui container"
    docker start open-webui >/dev/null
  else
    info "Pulling $OPEN_WEBUI_IMAGE and creating container"
    docker pull "$OPEN_WEBUI_IMAGE" >/dev/null
    docker run -d --name open-webui --restart always --network host \
      -v open-webui:/app/backend/data \
      "$OPEN_WEBUI_IMAGE" >/dev/null
  fi
  ok "open-webui container ready"
}

# ============================================================================
# Final verification
# ============================================================================
verify_e2e() {
  step "Final verification"

  sleep 8
  local ok_all=1
  local code

  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 http://127.0.0.1:8001/v1/models)
  if [[ "$code" == "200" ]]; then
    ok "llama-swap :8001 responds 200"
    curl -s --max-time 5 http://127.0.0.1:8001/v1/models | jq -r '.data[].id' \
      | sed 's/^/    model: /'
  else
    warn "llama-swap :8001 returned HTTP $code"
    ok_all=0
  fi

  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 http://127.0.0.1:3456/)
  [[ "$code" == "200" ]] && ok "ccr :3456 responds 200" || { warn "ccr :3456 HTTP $code"; ok_all=0; }

  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 http://127.0.0.1:3000/health || echo 000)
  if [[ "$code" == "200" ]]; then
    ok "open-webui :3000 responds 200"
  else
    warn "open-webui :3000 HTTP $code (may still be booting)"
  fi

  "$DOCS_DIR/scripts/healthcheck.sh" || ok_all=0
  return $((ok_all == 1 ? 0 : 1))
}

print_summary() {
  local ip
  ip=$(hostname -I | awk '{print $1}')
  cat <<EOF

╔═══════════════════════════════════════════════════════════════════╗
║  Install complete                                                 ║
╠═══════════════════════════════════════════════════════════════════╣
║  ccr endpoint  : http://${ip}:3456
║  ccr APIKEY    : $CCR_APIKEY
║  Open WebUI    : http://${ip}:3000
║                                                                   ║
║  Windows client setup (Claude Code):                              ║
║    setx ANTHROPIC_BASE_URL  "http://${ip}:3456"
║    setx ANTHROPIC_AUTH_TOKEN "$CCR_APIKEY"
║    setx ANTHROPIC_API_KEY ""
║                                                                   ║
║  Switch local model from Open WebUI:                              ║
║    Settings → Connections → ↻  (refresh model list)               ║
║    Pick qwen2.5-14b-coder or gemma-3-4b-familiar in chat picker.  ║
║                                                                   ║
║  Maintenance scripts in $DOCS_DIR/scripts/:
║    healthcheck.sh   update-stack.sh   backup.sh                   ║
╚═══════════════════════════════════════════════════════════════════╝
EOF
}

# ============================================================================
# Main
# ============================================================================
main() {
  preflight
  check_nvidia
  ensure_apt
  ensure_cuda
  ensure_python
  ensure_node
  ensure_docker
  ensure_llama_cpp
  ensure_models
  ensure_ccr
  ensure_llama_swap
  ensure_configs
  ensure_systemd
  ensure_open_webui
  verify_e2e || warn "Final verification reported issues. See output above."
  print_summary
}

main "$@"
