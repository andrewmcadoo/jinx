#!/usr/bin/env bash
# install/70-helpers.sh — install jinx-* helpers + refresh-ssh-keys to /usr/local/bin.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "${SCRIPT_DIR}/lib.sh"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

for helper in jinx-status jinx-caddy-apply jinx-prune-releases jinx-healthcheck-ping; do
    install -m 0755 -o root -g root \
        "${REPO_ROOT}/helpers/${helper}" "/usr/local/bin/${helper}"
    log "installed /usr/local/bin/${helper}"
done

install -m 0755 -o root -g root \
    "${REPO_ROOT}/scripts/refresh-ssh-keys.sh" /usr/local/bin/refresh-ssh-keys
log "installed /usr/local/bin/refresh-ssh-keys"
