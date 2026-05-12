#!/usr/bin/env bash
# install/80-monitoring.sh — journald cap, prune cron, healthcheck cron.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "${SCRIPT_DIR}/lib.sh"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

install -d -m 0755 /etc/systemd/journald.conf.d
install -m 0644 -o root -g root \
    "${REPO_ROOT}/monitoring/journald-jinx.conf" \
    /etc/systemd/journald.conf.d/jinx.conf
log "installed journald cap (500M)"

install -m 0755 -o root -g root \
    "${REPO_ROOT}/monitoring/cron-prune-releases" \
    /etc/cron.daily/jinx-prune-releases
log "installed /etc/cron.daily/jinx-prune-releases"

install -m 0644 -o root -g root \
    "${REPO_ROOT}/monitoring/cron-healthchecks" \
    /etc/cron.d/jinx-healthchecks
log "installed /etc/cron.d/jinx-healthchecks"

# Make /etc/jinx/ exist (empty) so operator can drop in healthchecks-url later.
install -d -m 0755 -o root -g root /etc/jinx

# Restart journald to apply the new cap (best-effort in containers).
systemctl restart systemd-journald 2>/dev/null \
    || log "journald restart not possible here (likely container); skipping"
