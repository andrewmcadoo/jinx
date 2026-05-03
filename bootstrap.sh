#!/usr/bin/env bash
# bootstrap.sh — first-boot configuration for Jinx (jinx.generalproducts.io).
#
# Run once as the Lightsail launch script (cloud-init user-data). Idempotent:
# safe to re-run (e.g. after a snapshot restore) — every section guards against
# repeated work.
#
# Spec: docs/superpowers/specs/2026-05-03-jinx-scratch-box-design.md

set -euo pipefail

# --- Configuration ---
GITHUB_HANDLE="andrewmcadoo"
LINUX_USER="andrew"
SRV_ROOT="/srv"
LOG_FILE="/var/log/jinx-bootstrap.log"

# --- Helpers ---
log() {
    printf '[bootstrap] %s\n' "$*" | tee -a "$LOG_FILE"
}

require_root() {
    if [[ $EUID -ne 0 ]]; then
        log "ERROR: must run as root (currently $EUID)"
        exit 1
    fi
}

# Install OS packages and Caddy from the official Cloudsmith apt repo.
# Idempotent: apt-get install --no-upgrade is a no-op if already installed.
install_packages() {
    log "Updating apt cache"
    DEBIAN_FRONTEND=noninteractive apt-get update -qq

    log "Installing baseline packages"
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        ca-certificates curl gnupg ufw unattended-upgrades

    if ! command -v caddy >/dev/null; then
        log "Adding Caddy apt repo"
        curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
            | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
        curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
            | tee /etc/apt/sources.list.d/caddy-stable.list >/dev/null
        DEBIAN_FRONTEND=noninteractive apt-get update -qq
        DEBIAN_FRONTEND=noninteractive apt-get install -y caddy
    else
        log "Caddy already installed: $(caddy version | head -1)"
    fi
}

# --- Main ---
main() {
    require_root
    log "Starting Jinx bootstrap at $(date -u --iso-8601=seconds)"
    log "Config: user=$LINUX_USER handle=$GITHUB_HANDLE srv=$SRV_ROOT"
    install_packages
    log "Bootstrap complete"
}

main "$@"
