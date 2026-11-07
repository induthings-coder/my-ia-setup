#!/usr/bin/env bash
#
# stop-ai-for-sandbox.sh
# Temporarily stop every AI service on this host so the P100 is free for a
# computer-vision sandbox, then verify the GPU is clean.
#
# Frees:  llama-swap (+ its llama-server children on the P100) or Strata, ccr, Open WebUI.
# Keeps:  nvidia-persistenced running -- CUDA (and the CV sandbox) needs it, and
#         stopping it is what breaks the P100 driver. Do NOT stop it.
#
# Restore afterwards:  ./start-ai-after-sandbox.sh   (or the one-liner at the end)

set -uo pipefail

say() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }

say "Stopping Open WebUI (Docker)"
# --restart always means it stays down until the next daemon restart / reboot.
docker stop open-webui 2>/dev/null && echo "open-webui stopped" || echo "open-webui not running"

say "Stopping ccr.service (Claude Code router)"
sudo systemctl stop ccr

say "Stopping the local model server (llama-swap or Strata)"
sudo systemctl stop llama-swap
sudo systemctl stop strata 2>/dev/null || true

say "Reaping any stray llama-server processes"
if pgrep -x llama-server >/dev/null; then
    sudo pkill -TERM -x llama-server
    for i in $(seq 1 10); do
        pgrep -x llama-server >/dev/null || break
        sleep 1
    done
    if pgrep -x llama-server >/dev/null; then
        echo "Still alive after SIGTERM, sending SIGKILL"
        sudo pkill -KILL -x llama-server
        sleep 2
    fi
    echo "llama-server processes cleared"
else
    echo "no stray llama-server processes"
fi

# ---------------------------------------------------------------------------
say "Verifying GPU is clean"

echo "Services (nvidia-persistenced should stay active):"
systemctl is-active nvidia-persistenced llama-swap strata ccr | \
    paste -d' ' <(printf 'nvidia-persistenced:\nllama-swap:\nstrata:\nccr:\n') -

echo
echo "P100 memory / utilisation:"
nvidia-smi --query-gpu=name,memory.used,memory.total,utilization.gpu --format=csv

echo
echo "Compute processes still on the GPU:"
apps="$(nvidia-smi --query-compute-apps=pid,process_name,used_memory --format=csv,noheader)"
if [ -z "$apps" ]; then
    echo "  (none)"
else
    echo "$apps" | sed 's/^/  /'
fi

echo
used_mib="$(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits | head -1 | tr -d ' ')"
if [ -z "$apps" ] && [ "${used_mib:-0}" -lt 500 ]; then
    printf '\033[1;32m✔ GPU is clean (%s MiB used, no compute apps). Sandbox can take the P100.\033[0m\n' "$used_mib"
else
    printf '\033[1;31m�’ GPU NOT clean: %s MiB used, compute apps above. Investigate before launching the sandbox.\033[0m\n' "$used_mib"
    exit 1
fi

echo
echo "Restore AI later with:"
echo "  sudo systemctl start ccr && docker start open-webui && ai-mode \$(systemctl is-enabled --quiet strata && echo strata || echo classic)"
