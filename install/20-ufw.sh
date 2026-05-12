#!/usr/bin/env bash
# install/20-ufw.sh — UFW: deny in, allow 22 + 443.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "${SCRIPT_DIR}/lib.sh"

log "Configuring UFW"
ufw --force reset >/dev/null
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp comment 'SSH'
ufw allow 443/tcp comment 'HTTPS via Caddy'
ufw --force enable
ufw status verbose | tee -a "$JINX_LOG_FILE"
