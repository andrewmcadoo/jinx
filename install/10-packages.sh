#!/usr/bin/env bash
# install/10-packages.sh — apt baseline, operator tooling, Caddy.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "${SCRIPT_DIR}/lib.sh"

export DEBIAN_FRONTEND=noninteractive

log "apt-get update"
retry apt-get update -qq

log "Installing baseline + operator tools"
apt-get install -y --no-install-recommends \
    ca-certificates curl gnupg ufw unattended-upgrades git \
    tmux htop jq rsync vim-tiny ncdu less openssl openssh-server

if ! command -v caddy >/dev/null; then
    log "Adding Caddy apt repo"
    retry bash -c "curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
        | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg"
    retry bash -c "curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
        | tee /etc/apt/sources.list.d/caddy-stable.list >/dev/null"
    retry apt-get update -qq
    apt-get install -y caddy
else
    caddy_v=$(caddy version 2>/dev/null) || caddy_v="(unknown)"
    log "Caddy already installed: ${caddy_v%%$'\n'*}"
fi

log "Configuring unattended-upgrades"
cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF
cat > /etc/apt/apt.conf.d/52unattended-upgrades-jinx <<'EOF'
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-Time "04:00";
EOF
systemctl enable unattended-upgrades >/dev/null 2>&1 || true
