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

# Configure UFW: deny inbound by default, allow SSH (22) and HTTPS (443).
# Port 80 is intentionally NOT opened — see spec §3.2.
configure_ufw() {
    log "Configuring UFW"
    ufw --force reset >/dev/null
    ufw default deny incoming
    ufw default allow outgoing
    ufw allow 22/tcp comment 'SSH'
    ufw allow 443/tcp comment 'HTTPS via Caddy'
    ufw --force enable
    ufw status verbose | tee -a "$LOG_FILE"
}

# Enable unattended security upgrades. Reboot at 04:00 UTC if a kernel
# update requires it.
configure_unattended_upgrades() {
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
    systemctl enable --now unattended-upgrades
}

# Create the single Linux user, populate authorized_keys from GitHub.
# Idempotent: useradd is no-op if user exists; key file is overwritten.
configure_user() {
    log "Configuring user $LINUX_USER"
    if ! id "$LINUX_USER" >/dev/null 2>&1; then
        useradd --create-home --shell /bin/bash --groups sudo "$LINUX_USER"
    fi

    local ssh_dir="/home/${LINUX_USER}/.ssh"
    install -d -m 0700 -o "$LINUX_USER" -g "$LINUX_USER" "$ssh_dir"

    log "Pulling SSH keys for $GITHUB_HANDLE from GitHub"
    local keys_url="https://github.com/${GITHUB_HANDLE}.keys"
    local tmp_keys
    tmp_keys=$(mktemp)
    curl -fsSL "$keys_url" -o "$tmp_keys"
    if [[ ! -s "$tmp_keys" ]]; then
        log "ERROR: $keys_url returned no keys"
        rm -f "$tmp_keys"
        exit 1
    fi
    install -m 0600 -o "$LINUX_USER" -g "$LINUX_USER" "$tmp_keys" "${ssh_dir}/authorized_keys"
    rm -f "$tmp_keys"
    log "Installed $(wc -l < "${ssh_dir}/authorized_keys") SSH key(s)"
}

# Drop in sshd hardening config + base sudoers entry. Both validated before
# install (sshd -t / visudo -cf) so we never lock ourselves out.
configure_sshd_and_sudo() {
    log "Configuring sshd hardening"
    cat > /etc/ssh/sshd_config.d/90-jinx.conf <<'EOF'
# Jinx hardening — see spec §4.2.
PasswordAuthentication no
PermitRootLogin no
AuthenticationMethods publickey
ChallengeResponseAuthentication no
KbdInteractiveAuthentication no
EOF

    # Validate before reload — sshd refuses to start with a bad config.
    sshd -t
    systemctl reload ssh

    log "Configuring sudoers for $LINUX_USER"
    local sudoers_tmp
    sudoers_tmp=$(mktemp)
    printf '%s ALL=(ALL) ALL\n' "$LINUX_USER" > "$sudoers_tmp"
    visudo -cf "$sudoers_tmp"  # exits non-zero on syntax error
    install -m 0440 -o root -g root "$sudoers_tmp" "/etc/sudoers.d/00-${LINUX_USER}"
    rm -f "$sudoers_tmp"
}

# Create the /srv tree, Caddy config dirs, log dir, and TLS material dir.
# Apex landing page gets a placeholder until the real index.html is deployed.
configure_filesystem() {
    log "Creating /srv and Caddy directories"
    install -d -m 0755 -o "$LINUX_USER" -g "$LINUX_USER" "$SRV_ROOT"
    install -d -m 0755 -o "$LINUX_USER" -g "$LINUX_USER" "${SRV_ROOT}/_apex"

    install -d -m 0755 -o root -g root /etc/caddy/sites
    install -d -m 0750 -o root -g caddy /etc/ssl/jinx
    install -d -m 0755 -o caddy -g caddy /var/log/caddy

    if [[ ! -f "${SRV_ROOT}/_apex/index.html" ]]; then
        log "Installing placeholder apex index.html"
        cat > "${SRV_ROOT}/_apex/index.html" <<'EOF'
<!doctype html>
<title>Jinx</title>
<h1>Jinx is up.</h1>
<p>Projects will appear here.</p>
EOF
        chown "$LINUX_USER:$LINUX_USER" "${SRV_ROOT}/_apex/index.html"
    fi
}

# Print the post-bootstrap manual checklist. Bootstrap intentionally does NOT
# install the Caddy config or the Origin Cert — those land via scp from the
# operator's laptop after first SSH (see spec §6.2 launch procedure).
print_manual_steps() {
    cat <<EOF | tee -a "$LOG_FILE"

==============================================================
Bootstrap finished. Remaining manual steps (from your laptop):

  1. scp caddy/Caddyfile andrew@<jinx-ip>:/tmp/
     scp caddy/sites/00-apex.caddy andrew@<jinx-ip>:/tmp/
     ssh jinx 'sudo install -m 0644 -o root -g root /tmp/Caddyfile /etc/caddy/Caddyfile
               sudo install -m 0644 -o root -g root /tmp/00-apex.caddy /etc/caddy/sites/00-apex.caddy
               rm /tmp/Caddyfile /tmp/00-apex.caddy'
  2. scp apex/index.html andrew@<jinx-ip>:/tmp/
     ssh jinx 'sudo install -m 0644 -o andrew -g andrew /tmp/index.html /srv/_apex/index.html'
  3. Generate Cloudflare Origin Cert; scp cert.pem + key.pem; install at
     /etc/ssl/jinx/ with cert 0644 root:caddy, key 0640 root:caddy.
  4. ssh jinx 'sudo systemctl enable --now caddy && sudo systemctl reload caddy'
  5. curl -I https://jinx.generalproducts.io   # expect 200
==============================================================
EOF
}

# --- Main ---
main() {
    require_root
    log "Starting Jinx bootstrap at $(date -u --iso-8601=seconds)"
    log "Config: user=$LINUX_USER handle=$GITHUB_HANDLE srv=$SRV_ROOT"
    install_packages
    configure_ufw
    configure_unattended_upgrades
    configure_user
    configure_sshd_and_sudo
    configure_filesystem
    print_manual_steps
    log "Bootstrap complete"
}

main "$@"
