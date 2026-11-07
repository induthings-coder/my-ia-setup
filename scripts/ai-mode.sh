#!/usr/bin/env bash
# Switch the local AI stack between its two layouts.
#
#   ai-mode strata   Qwen3.8-Flash-Next on Strata serves everything local.
#   ai-mode classic  llama-swap serves Qwen 2.5 7B, Gemma 3 and DeepSeek R1.
#   ai-mode status   Show the active layout and its health.
#
# ccr keeps one config per layout next to config.json. Open WebUI's connections
# are not touched: each layout's models simply appear when their server is up.
set -euo pipefail

CCR_DIR="$HOME/.claude-code-router"
STRATA_ENV="$HOME/strata-poc/strata.env"

die() { echo "ai-mode: $*" >&2; exit 1; }

wait_for() { # name url [auth header]
  local name=$1 url=$2 header=${3:-X-None: 0} code=000 i
  for i in $(seq 1 60); do
    code=$(curl -s -o /dev/null -m 5 -w '%{http_code}' -H "$header" "$url" || true)
    [[ "$code" == 200 ]] && { echo "$name is ready"; return 0; }
    sleep 5
  done
  die "$name did not become ready (last HTTP $code)"
}

use_ccr_config() {
  local source="$CCR_DIR/config.json.$1"
  [[ -f "$source" ]] || die "missing $source"
  install -m 0600 "$source" "$CCR_DIR/config.json"
  sudo systemctl restart ccr
}

status() {
  local mode=unknown
  systemctl is-enabled --quiet strata 2>/dev/null && mode=strata
  systemctl is-enabled --quiet llama-swap 2>/dev/null && mode=classic
  echo "layout:              $mode"
  for unit in strata llama-swap ccr nvidia-persistenced; do
    printf '%-20s %s\n' "$unit:" "$(systemctl is-active "$unit" || true)"
  done
  nvidia-smi --query-gpu=persistence_mode,memory.used,memory.total --format=csv,noheader
}

case "${1:-status}" in
  strata)
    [[ -f "$STRATA_ENV" ]] || die "missing $STRATA_ENV"
    sudo systemctl disable --now llama-swap
    sudo systemctl enable --now strata
    wait_for Strata "http://127.0.0.1:8080/v1/models" "Authorization: Bearer $(cut -d= -f2 "$STRATA_ENV")"
    use_ccr_config strata
    status
    ;;
  classic)
    sudo systemctl disable --now strata
    sudo systemctl enable --now llama-swap
    wait_for llama-swap "http://127.0.0.1:8001/v1/models"
    use_ccr_config classic
    status
    ;;
  status)
    status
    ;;
  *)
    die "usage: ai-mode strata|classic|status"
    ;;
esac
