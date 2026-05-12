#!/usr/bin/env bash
# install/30-user.sh — create andrew, pull authorized_keys from GitHub.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "${SCRIPT_DIR}/lib.sh"

GITHUB_HANDLE="${GITHUB_HANDLE:-andrewmcadoo}"

validate_ssh_keys_file() {
    local file="$1"
    [[ -s "$file" ]] || return 1
    if grep -vE '^(ssh-rsa|ssh-ed25519|ecdsa-sha2-nistp(256|384|521)|sk-ssh-ed25519@openssh\.com|sk-ecdsa-sha2-nistp256@openssh\.com)( |$)' "$file" \
         | grep -qE '\S'; then
        return 1
    fi
    return 0
}

log "Configuring user ${JINX_USER}"
if ! id "$JINX_USER" >/dev/null 2>&1; then
    useradd --create-home --shell /bin/bash --groups sudo "$JINX_USER"
fi
usermod -aG sudo "$JINX_USER"

ssh_dir="/home/${JINX_USER}/.ssh"
install -d -m 0700 -o "$JINX_USER" -g "$JINX_USER" "$ssh_dir"

log "Pulling SSH keys for $GITHUB_HANDLE from GitHub"
tmp_keys=$(mktemp)
trap 'rm -f "$tmp_keys"' EXIT

for attempt in 1 2 3; do
    if curl -fsSL --max-time 15 "https://github.com/${GITHUB_HANDLE}.keys" -o "$tmp_keys" \
        && validate_ssh_keys_file "$tmp_keys"; then
        break
    fi
    log "GitHub key fetch attempt $attempt failed; sleeping 5s"
    sleep 5
done

if ! validate_ssh_keys_file "$tmp_keys"; then
    log "ERROR: GitHub returned no valid keys for $GITHUB_HANDLE after 3 attempts"
    exit 1
fi

install -m 0600 -o "$JINX_USER" -g "$JINX_USER" "$tmp_keys" "${ssh_dir}/authorized_keys"
log "Installed $(wc -l < "${ssh_dir}/authorized_keys") SSH key(s)"
