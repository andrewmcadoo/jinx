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

# --- Main ---
main() {
    require_root
    log "Starting Jinx bootstrap at $(date -u --iso-8601=seconds)"
    log "Config: user=$LINUX_USER handle=$GITHUB_HANDLE srv=$SRV_ROOT"
    # Subsequent tasks fill in sections below.
    log "Bootstrap complete"
}

main "$@"
