# System inventory — IA-SERVER (192.168.1.199)

Captured 2026-05-04 against the running host. This file is a snapshot of
the deployed state across hardware, boot, drivers, Xorg/GDM, systemd
services, and AI stack components — meant to be a reference for full
reinstall or disaster recovery. Configuration *intent* lives in `README.md`
and `CLAUDE.md`; this file records *what is actually on the box right now*.

If you change the host, refresh this file. Drift is the enemy.

## Hardware

| Component         | Value |
| ----------------- | ----- |
| Hostname          | `IA-SERVER` |
| Motherboard       | HUANANZHI X99-TF, BIOS 5.11 (2022-09-16) |
| CPU               | Intel Xeon E5-2695 v4 @ 2.10 GHz (1 socket × 18 cores × 2 threads = 36 logical CPUs) |
| RAM               | 48 GB (49 218 600 kB) + 8 GB swap (`/swap.img`) |
| Boot disk         | Kingston KC2500 1 TB NVMe (`nvme0n1`) |
| GPU 0 (compute)   | Tesla P100 PCIe 16 GB at PCI `03:00.0`, vendor:device `10de:15f8`, VBIOS 86.00.4D.00.01, compute capability 6.0, driver `nvidia` 535.288.01 |
| GPU 1 (display)   | GeForce GT 730 (GK208B Kepler) at PCI `04:00.0`, vendor:device `10de:1287`, MSI variant, driver `nouveau` |
| NIC               | Realtek RTL8111/8168 (`enp6s0`, `r8169`), gigabit |
| Static IP         | `192.168.1.199/24`, gateway `192.168.1.1` |
| Secure Boot       | disabled (Setup Mode) |
| Time zone         | CEST (Europe/Madrid), RTC in UTC |
| Locale            | `en_US.UTF-8`, X11 keymap `latam` |

## Storage layout

```
nvme0n1                       931.5 G  Kingston KC2500
├─nvme0n1p1   1 G  vfat       /boot/efi
├─nvme0n1p2   2 G  ext4       /boot
└─nvme0n1p3 928.5 G  LUKS
  └─dm_crypt-0  → LVM ubuntu-vg/ubuntu-lv (ext4, /)
sda           3.8 G  vfat     /media/alex/CRYPTOKEY  (USB unlock key)
```

`/etc/crypttab` opens the root LUKS volume with a keyscript on a USB stick:

```
dm_crypt-0 UUID=b7a19264-0be9-4834-8e5c-a87c49ee57d5 none luks,initramfs,keyscript=/usr/lib/cryptsetup/keyscripts/usb-cryptkey
```

**Disaster recovery note:** the host *will not boot* without the USB key
inserted. Keep a copy of the LUKS header and the unlock token offline.

## OS and kernel

| Item            | Value |
| --------------- | ----- |
| Distribution    | Ubuntu 24.04.4 LTS (noble) |
| Kernel          | 6.17.0-22-generic (`#22~24.04.1-Ubuntu`, HWE branch) |
| Init / service  | systemd |
| Display server  | X.Org (Wayland disabled in `/etc/gdm3/custom.conf`) |
| Display manager | gdm3 46.2-1ubuntu1~24.04.7 |

## Boot

GRUB defaults (`/etc/default/grub`):

```
GRUB_DEFAULT=0
GRUB_TIMEOUT_STYLE=hidden
GRUB_TIMEOUT=5
GRUB_DISTRIBUTOR=`( . /etc/os-release; echo ${NAME:-Ubuntu} ) 2>/dev/null || echo Ubuntu`
GRUB_CMDLINE_LINUX_DEFAULT="quiet splash nouveau.modeset=1"
GRUB_CMDLINE_LINUX=""
```

Live kernel cmdline:

```
BOOT_IMAGE=/vmlinuz-6.17.0-22-generic root=/dev/mapper/ubuntu--vg-ubuntu--lv ro quiet splash nouveau.modeset=1 vt.handoff=7
```

EFI boot entries (output of `efibootmgr`):

```
BootOrder: 0003,0004,0002,0000,0001
Boot0003* ubuntu                 → \EFI\UBUNTU\GRUBX64.EFI
Boot0002  Windows Boot Manager   → \EFI\MICROSOFT\BOOT\BOOTMGFW.EFI
Boot0004* UEFI: Generic Flash Disk 8.00 (USB)
```

The host dual-boots Windows; ubuntu is set first.

## NVIDIA driver layout

Installed packages (key ones):

| Package                  | Version |
| ------------------------ | ------- |
| `nvidia-driver-535`      | 535.288.01-0ubuntu0.24.04.2 |
| `cuda-toolkit-12-6`      | 12.6.3-1 |
| `xserver-xorg-core`      | 2:21.1.12-1ubuntu1.5 |
| `xserver-xorg-legacy`    | 2:21.1.12-1ubuntu1.5 |
| `xserver-xorg-video-nouveau` | 1:1.0.17-2ubuntu0.1 |
| `gdm3`                   | 46.2-1ubuntu1~24.04.7 |

`/etc/modprobe.d/` (NVIDIA-relevant entries — see `CLAUDE.md`'s
"Module parameter hygiene" section for what to keep clean):

| File | Content (uncommented) |
| ---- | --------------------- |
| `gt730-fix.conf` | `options nouveau modeset=1` (and `alias oem-audio-hda-daily-dkms off`) |
| `nvidia-graphics-drivers-kms.conf` | `options nvidia-drm modeset=0` |
| `blacklist-framebuffer.conf` | blacklists `nvidiafb`, `rivafb`, etc. (Ubuntu default) |

`prime-select query` → `on-demand`.

`/etc/udev/rules.d/99-hide-p100-from-desktop.rules`:

```
SUBSYSTEM=="drm", KERNELS=="0000:03:00.0", TAG-="seat", ENV{ID_FOR_SEAT}=""
SUBSYSTEM=="graphics", KERNELS=="0000:03:00.0", TAG-="seat", ENV{ID_FOR_SEAT}=""
```

This removes the P100's DRM and graphics nodes from `seat0` so logind
does not try to grant Xorg sessions access to them. Without this the
`(EE) systemd-logind: failed to take device /dev/dri/card1` line in the
Xorg log can escalate from informational to a startup failure.

`fix-gpu.service` (oneshot, runs **before** `display-manager.service`):

```ini
[Unit]
Description=Fix GPU Driver Assignment (P100 to NVIDIA)
Before=display-manager.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/fix-gpu-drivers.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
```

`/usr/local/bin/fix-gpu-drivers.sh`:

```bash
#!/bin/bash
echo "0000:03:00.0" > /sys/bus/pci/drivers/nouveau/unbind 2>/dev/null
modprobe nvidia
modprobe nvidia_uvm
```

This unbinds the P100 from `nouveau` (in case it was attached during
early boot) and ensures the proprietary `nvidia` + `nvidia_uvm` modules
are loaded before GDM starts. Combined with `nvidia-drm modeset=0` and
the udev rule above, this leaves `nouveau` driving only the GT 730.

`nvidia-persistenced.service` is the stock Ubuntu unit, overridden by
`/etc/systemd/system/nvidia-persistenced.service.d/override.conf`:

```ini
[Unit]
StopWhenUnneeded=false

[Service]
ExecStart=
ExecStart=/usr/bin/nvidia-persistenced --user nvidia-persistenced --verbose
```

## Xorg layout

`/etc/X11/Xwrapper.config` (Ubuntu default, kept):

```
allowed_users=console
```

`/etc/X11/xorg.conf.d/00-video.conf` (legacy, retained for the `Ignore` on the P100):

```
Section "Device"
    Identifier     "GT730"
    Driver         "nouveau"
    BusID          "PCI:4:0:0"
EndSection
Section "Device"
    Identifier     "P100"
    Driver         "nvidia"
    BusID          "PCI:3:0:0"
    Option         "Ignore" "yes"
EndSection
Section "Screen"
    Identifier     "Screen0"
    Device         "GT730"
EndSection
```

`/etc/X11/xorg.conf.d/10-gt730-only.conf` (current, supersedes the
GT730/Screen0 sections in `00-video.conf` because of lexical order):

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

`/usr/share/X11/xorg.conf.d/20-gt730.conf.disabled` — older snippet kept
disabled in case anyone wonders why it is there. Do not re-enable: it
declares `Driver "nouveau"` for the GT 730 with no `Screen` section,
which conflicts with `10-gt730-only.conf`.

## GDM

`/etc/gdm3/custom.conf` (relevant lines):

```
[daemon]
WaylandEnable=false
```

`gdm` user groups: `gdm`, `video`, `render`. Required for Xorg launched
by gdm to access `/dev/fb0`, `/dev/dri/card0`, and `/dev/dri/renderD128`.

`/etc/systemd/system/display-manager.service` is a symlink to
`/lib/systemd/system/gdm3.service`.

## AI stack — systemd

Active services:

| Unit                          | State    | Owner    | Notes |
| ----------------------------- | -------- | -------- | ----- |
| `nvidia-persistenced.service` | active   | root     | overridden (see above); pulled up by `llama-swap` |
| `fix-gpu.service`             | oneshot  | root     | runs before `display-manager` |
| `gdm.service`                 | active   | root     | display manager |
| `llama-swap.service`          | active   | `alex`   | port 8001, drop-in pulls in `nvidia-persistenced` |
| `ccr.service`                 | active   | `alex`   | port 3456, npm-installed `ccr` binary |
| `ai-healthcheck.timer`        | enabled  | `alex`   | every 5 min → `ai-healthcheck.service` |
| `ai-backup.timer`             | enabled  | `alex`   | daily 03:00 → `ai-backup.service` |
| `open-webui` (Docker)         | running  | docker   | bridge net, port 3000, `--restart always`, **no volumes** |
| `ollama.service`              | active   | `ollama` | listens on `127.0.0.1:11434`, holds `qwen2.5-coder:14b-instruct-q8_0` (15 GB). Not used by `ccr`/`llama-swap`; legacy/optional. |

Drop-ins:

```ini
# /etc/systemd/system/llama-swap.service.d/nvidia-persistenced.conf
[Unit]
Wants=nvidia-persistenced.service
After=nvidia-persistenced.service
```

```ini
# /etc/systemd/system/nvidia-persistenced.service.d/override.conf
[Unit]
StopWhenUnneeded=false

[Service]
ExecStart=
ExecStart=/usr/bin/nvidia-persistenced --user nvidia-persistenced --verbose
```

`ai-healthcheck.service` runs `/home/alex/ai-setup-docs/scripts/healthcheck.sh`;
`ai-backup.service` runs `/home/alex/ai-setup-docs/scripts/backup.sh`. Both
scripts live in `/home/alex/ai-setup-docs/`, **not** in this repo. See
"Two source-of-truth trees" below.

`/etc/sudoers.d/ai-stack` grants user `alex` passwordless `systemctl`
on the AI units only (start/stop/restart/reload + `daemon-reload`).

## Listening ports

```
0.0.0.0:3000   docker-proxy   (Open WebUI)
0.0.0.0:3456   node (ccr)
*:8001         llama-swap
127.0.0.1:11434 ollama
```

`ufw` is **inactive** — firewalling relies on the LAN being trusted.

## llama.cpp / llama-swap

- Source: `~/llama.cpp/` (commit `a8bad3842`, version 8780).
- Build flags: `GGML_CUDA=ON`, `CMAKE_CUDA_ARCHITECTURES=60`,
  `GGML_CUDA_FA=ON`, `GGML_CUDA_COMPRESSION_MODE=size`.
- Symlinks: `/usr/local/bin/llama-server`, `/usr/local/bin/llama-cli`
  → `~/llama.cpp/build/bin/`.
- llama-swap binary: `/usr/local/bin/llama-swap`, version 210.

`~/.config/llama-swap/config.yaml` is the canonical config; see the
"## Post-install changes / 2. Update `~/.config/llama-swap/config.yaml`"
section of `README.md` for the full file. Summary of the deployed state:

- always-on gpu group (swap=false): `qwen2.5-coder-7b` + `gemma-3-4b-familiar`
- opt-in gpu-heavy (exclusive=true): `qwen2.5-14b-coder`
- always-on cpu (persistent=true): `deepseek-r1-distill-7b`
- `hooks.on_startup.preload` warms the three permanent models at boot

## ccr

`~/.claude-code-router/config.json` — Anthropic-compatible router.
Highlights (secrets redacted):

- `HOST=0.0.0.0`, `PORT=3456`, `API_TIMEOUT_MS=600000`, `LOG=true`
- Providers: `local` → `http://localhost:8001/v1/chat/completions`
  (with custom `strip-billing-header` transformer + standard `Anthropic`
  for `anthropic`)
- Router: `default→anthropic,claude-sonnet-4-6`,
  `background→local,qwen2.5-coder-7b`,
  `think→anthropic,claude-opus-4-7`,
  `longContext→anthropic,claude-opus-4-7` (threshold 60 000 tokens)
- Custom transformer: `~/.claude-code-router/plugins/strip-billing-header.js`

The `local` provider also claims the haiku model IDs
(`claude-3-5-haiku-20241022`, `claude-haiku-4-5`,
`claude-haiku-4-5-20251001`) so Claude Code subagents that pin to a
haiku route through Qwen 7B.

## Open WebUI

```
container: open-webui
image:     ghcr.io/open-webui/open-webui:main
network:   bridge
ports:     0.0.0.0:3000 → 8080/tcp
restart:   always
mounts:    (none)
```

⚠️ **No bind mount or named volume.** Container-internal
`/app/backend/data/` (with `webui.db`, `vector_db/`, `uploads/`, `cache/`)
holds chat history, configuration, and embeddings. If the container is
ever removed (e.g. by `docker rm` during an image update), all of that
is lost. The daily `ai-backup.sh` is the only safety net — verify it
captures `webui.db` before relying on it.

The container does **not** use `--network host` despite earlier
documentation suggesting otherwise. With bridge networking, Open WebUI's
`OPENAI_API_BASE_URL` must point at the host gateway
(e.g. `http://192.168.1.199:8001/v1`) or `host.docker.internal`, not
`localhost`. The current value is set from the admin UI, not via
environment variables.

## ~/.models inventory

| File | Size | Use |
| ---- | ---- | --- |
| `Qwen2.5-Coder-7B-Instruct-Q4_K_M.gguf` | 4.4 GB | gpu group, default |
| `Qwen2.5-14B-Instruct-Q4_K_M.gguf` | 8.4 GB | gpu-heavy, opt-in |
| `google_gemma-3-4b-it-Q5_K_M.gguf` + `mmproj-google_gemma-3-4b-it-f16.gguf` | 2.7 GB + 0.8 GB | gpu group, vision |
| `DeepSeek-R1-Distill-Qwen-7B-Q4_K_M.gguf` | 4.4 GB | cpu group |
| `Qwen3.6-27B-UD-Q3_K_XL.gguf` | 14 GB | unused; experimental |
| `mmproj-google_gemma-3-4b-it-bf16.gguf`, `…-f32.gguf` | 0.8 / 1.6 GB | unused alternates |
| `mistral-7b/`, `mistral-v0.3/`, `llama-70b/` | dirs | unused; experimental |

## Two source-of-truth trees on the host

This is intentional but worth flagging:

| Path | Role |
| ---- | ---- |
| `/home/alex/projects/my-ia-setup/` | **GitHub-tracked** docs + install script (`induthings-coder/my-ia-setup`). `CLAUDE.md` and `README.md` are the canonical *deployment* documentation. |
| `/home/alex/ai-setup-docs/` | Older working tree. Live systemd units still reference its `scripts/` (`backup.sh`, `healthcheck.sh`, `llama-launch.sh`, `update-stack.sh`) and `sudoers.d/ai-stack` source. **Do not delete** without first migrating these references to the GitHub repo. |

## Reproduce-from-zero outline

If the disk dies and you need to rebuild:

1. **OS install** Ubuntu 24.04, full-disk encryption, restore the LUKS
   header from offline backup, plug in the USB unlock key.
2. **GRUB** apply the cmdline above (`quiet splash nouveau.modeset=1`).
3. **Drivers** `apt install nvidia-driver-535 cuda-toolkit-12-6`. Reinstate
   `gt730-fix.conf` and verify `nvidia-graphics-drivers-kms.conf` ships
   `nvidia-drm modeset=0`.
4. **GPU split** drop in `99-hide-p100-from-desktop.rules`,
   `fix-gpu.service` + `/usr/local/bin/fix-gpu-drivers.sh`,
   `nvidia-persistenced` override.
5. **Xorg / GDM** `usermod -aG video,render gdm`, drop in
   `10-gt730-only.conf`, retain the `Ignore` for the P100 in
   `00-video.conf`, restart gdm.
6. **AI stack** run `my-ia-setup-install.sh` from the repo (idempotent;
   sets up llama.cpp build, llama-swap, ccr, Open WebUI, sudoers, timers).
7. **Models** restore `~/.models/` from the latest `ai-backup` archive,
   plus the Open WebUI `webui.db` from the same backup.
8. **Smoke test** `systemctl is-active nvidia-persistenced llama-swap ccr gdm`,
   `curl /v1/models` on 8001, ccr `/v1/messages` on 3456, Open WebUI on 3000.
   Confirm the monitor connected to the GT 730 shows the GDM greeter.
