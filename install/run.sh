#!/usr/bin/env bash
# install/run.sh — orchestrates install/NN-*.sh in numeric order.
set -euo pipefail
IFS=$'\n\t'
umask 022

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "${SCRIPT_DIR}/lib.sh"

require_root

trap 'log "ERROR: step ${JINX_STEP:-?} failed at line ${LINENO}: ${BASH_COMMAND}"' ERR

JINX_STEP=run log "Starting install at $(date -u --iso-8601=seconds)"

shopt -s nullglob
steps=("${SCRIPT_DIR}"/[0-9][0-9]-*.sh)
shopt -u nullglob

if [[ ${#steps[@]} -eq 0 ]]; then
    JINX_STEP=run log "No install steps found in ${SCRIPT_DIR}"
    exit 0
fi

for step in "${steps[@]}"; do
    name="$(basename "$step" .sh)"
    export JINX_STEP="$name"
    log "begin"
    bash "$step"
    log "ok"
done

JINX_STEP=run log "All steps complete"
