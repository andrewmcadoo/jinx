#!/usr/bin/env bash
# install/15-swap.sh — 2 GB swapfile.
#
# Lightsail's small_3_0 bundle ships with 1.9 GB RAM and no swap. Postgres +
# Node + Caddy + uv-cache + apt operations have OOM'd in practice (incident
# 2026-05-15: post-OOM sshd wedge that survived a warm reboot and required a
# Stop+Start to clear). Swap doesn't make the box faster, but it gives the
# kernel headroom to avoid OOM-kill cascades that leave services in degraded
# state. swappiness=10 keeps RAM the preferred allocation.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "${SCRIPT_DIR}/lib.sh"

SWAPFILE=/swapfile
SWAP_SIZE_MB=2048

if swapon --show=NAME --noheadings | grep -qx "$SWAPFILE"; then
    log "Swap already active at $SWAPFILE"
else
    if [[ ! -f "$SWAPFILE" ]]; then
        log "Allocating ${SWAP_SIZE_MB} MB at $SWAPFILE"
        fallocate -l "${SWAP_SIZE_MB}M" "$SWAPFILE"
        chmod 0600 "$SWAPFILE"
        mkswap "$SWAPFILE" >/dev/null
    fi
    log "Activating $SWAPFILE"
    swapon "$SWAPFILE"
fi

if ! grep -qE "^${SWAPFILE//\//\\/}\s" /etc/fstab; then
    log "Persisting $SWAPFILE in /etc/fstab"
    printf '%s\tnone\tswap\tsw\t0 0\n' "$SWAPFILE" >> /etc/fstab
fi

log "Tuning vm.swappiness=10 (prefer RAM, swap only under real pressure)"
sysctl -q -w vm.swappiness=10
install -m 0644 /dev/null /etc/sysctl.d/60-jinx-swap.conf
printf 'vm.swappiness = 10\n' > /etc/sysctl.d/60-jinx-swap.conf

log "Swap configured: $(swapon --show=NAME,SIZE,USED --noheadings | tr -s ' ')"
