#!/usr/bin/env bash
# install/50-filesystem.sh — /srv tree, Caddy config dirs, TLS dir, log dir.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "${SCRIPT_DIR}/lib.sh"

SRV_ROOT="${SRV_ROOT:-/srv}"

log "Creating /srv and Caddy directories"
install -d -m 0755 -o "$JINX_USER" -g "$JINX_USER" "$SRV_ROOT"
install -d -m 0755 -o "$JINX_USER" -g "$JINX_USER" "${SRV_ROOT}/_apex"

install -d -m 0755 -o root -g root /etc/caddy/sites
install -d -m 0750 -o root -g caddy /etc/ssl/jinx
install -d -m 0755 -o caddy -g caddy /var/log/caddy

# Pre-create caddy.log + apex.log, plus any per-site logs already declared
# under /etc/caddy/sites/*.caddy (snapshot-restore safe).
declare -a log_files=("caddy.log" "apex.log")
if compgen -G "/etc/caddy/sites/*.caddy" >/dev/null; then
    while IFS= read -r path; do
        log_files+=("$(basename "$path")")
    done < <(grep -hE '^[[:space:]]*output file /var/log/caddy/[^[:space:]]+\.log' \
             /etc/caddy/sites/*.caddy 2>/dev/null | awk '{print $3}')
fi
for f in "${log_files[@]}"; do
    if [[ ! -f "/var/log/caddy/${f}" ]]; then
        install -m 0644 -o caddy -g caddy /dev/null "/var/log/caddy/${f}"
    fi
done

log "Filesystem layout ready"
