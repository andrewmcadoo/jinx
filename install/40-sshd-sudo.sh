#!/usr/bin/env bash
# install/40-sshd-sudo.sh — sshd hardening + sudoers (from repo files).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "${SCRIPT_DIR}/lib.sh"

REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

log "Installing sshd hardening from sshd/90-jinx.conf"
install -d -m 0755 /etc/ssh/sshd_config.d
install -m 0644 -o root -g root \
    "${REPO_ROOT}/sshd/90-jinx.conf" /etc/ssh/sshd_config.d/90-jinx.conf
# /run/sshd is created by openssh-server's postinst on a real boot; in a
# container the service start is suppressed (policy-rc.d 101) so the dir is
# absent.  sshd -t requires it even for a config-only test.
mkdir -p /run/sshd
sshd -t
# `systemctl reload ssh` only matters when sshd is running; not in container.
if systemctl is-active --quiet ssh 2>/dev/null; then
    systemctl reload ssh
else
    log "sshd not active (probably container); skipping reload"
fi

log "Installing sudoers/00-andrew"
visudo -cf "${REPO_ROOT}/sudoers/00-andrew"
install -m 0440 -o root -g root \
    "${REPO_ROOT}/sudoers/00-andrew" /etc/sudoers.d/00-andrew

if [[ "${JINX_NOPASSWD:-0}" == "1" ]]; then
    log "JINX_NOPASSWD=1 set; installing sudoers/01-andrew-nopasswd"
    visudo -cf "${REPO_ROOT}/sudoers/01-andrew-nopasswd"
    install -m 0440 -o root -g root \
        "${REPO_ROOT}/sudoers/01-andrew-nopasswd" /etc/sudoers.d/01-andrew-nopasswd
else
    log "JINX_NOPASSWD not set; skipping blanket NOPASSWD"
fi
