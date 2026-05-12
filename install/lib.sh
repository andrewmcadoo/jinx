#!/usr/bin/env bash
# install/lib.sh — shared helpers sourced by every install/NN-*.sh.
# Not executable; sourced via `. "$(dirname "$0")/lib.sh"`.

# These globals are exported so child scripts can rely on them.
: "${JINX_LOG_FILE:=/var/log/jinx-bootstrap.log}"
: "${JINX_USER:=andrew}"
export JINX_LOG_FILE JINX_USER

log() {
    printf '[%s] %s\n' "${JINX_STEP:-bootstrap}" "$*" | tee -a "$JINX_LOG_FILE"
}

require_root() {
    if [[ $EUID -ne 0 ]]; then
        printf '[bootstrap] ERROR: must run as root (currently %s)\n' "$EUID" >&2
        exit 1
    fi
}

# Retry a command up to 3 times with 5s sleep between attempts.
retry() {
    local attempt
    for attempt in 1 2 3; do
        if "$@"; then
            return 0
        fi
        log "Command failed (attempt $attempt/3): $*"
        sleep 5
    done
    log "ERROR: command failed after 3 attempts: $*"
    return 1
}
