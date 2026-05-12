#!/usr/bin/env bash
# bootstrap.sh — first-boot configuration for Jinx.
#
# Runs as Lightsail cloud-init user-data. Installs git, clones this repo
# to /opt/jinx, then execs install/run.sh. Idempotent: safe to re-run
# (e.g. after snapshot restore) — re-running re-pulls the repo and
# re-runs every install step.
#
# Spec: docs/superpowers/specs/2026-05-11-bootstrap-rework-design.md

set -euo pipefail
umask 022

JINX_REPO="${JINX_REPO:-https://github.com/andrewmcadoo/jinx.git}"
JINX_REF="${JINX_REF:-main}"
JINX_DIR="${JINX_DIR:-/opt/jinx}"
LOG_FILE=/var/log/jinx-bootstrap.log

log() { printf '[bootstrap] %s\n' "$*" | tee -a "$LOG_FILE"; }

if [[ $EUID -ne 0 ]]; then
    printf '[bootstrap] ERROR: must run as root (currently %s)\n' "$EUID" >&2
    exit 1
fi

log "Bootstrap start $(date -u '+%Y-%m-%dT%H:%M:%SZ'), repo=$JINX_REPO ref=$JINX_REF"

# Minimal apt prereqs needed just to clone the repo. install/10-packages.sh
# handles the full package set afterward.
export DEBIAN_FRONTEND=noninteractive
for attempt in 1 2 3; do
    if apt-get update -qq; then break; fi
    log "apt-get update failed (attempt $attempt/3); sleeping 5s"
    sleep 5
done
apt-get install -y --no-install-recommends ca-certificates curl git

# Clone or pull-update the repo. Re-runs re-converge on $JINX_REF.
if [[ -d "${JINX_DIR}/.git" ]]; then
    log "Updating existing repo at ${JINX_DIR}"
    git -C "$JINX_DIR" fetch --quiet origin
    git -C "$JINX_DIR" checkout --quiet "$JINX_REF"
    git -C "$JINX_DIR" pull --quiet --ff-only || log "pull --ff-only failed; staying at current ref"
else
    log "Cloning ${JINX_REPO} → ${JINX_DIR} at ref ${JINX_REF}"
    git clone --quiet --branch "$JINX_REF" "$JINX_REPO" "$JINX_DIR"
fi

current_ref=$(git -C "$JINX_DIR" rev-parse --short HEAD)
log "Handing off to install/run.sh at ${current_ref}"

exec bash "${JINX_DIR}/install/run.sh"
