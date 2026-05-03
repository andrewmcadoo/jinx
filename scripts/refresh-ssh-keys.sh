#!/usr/bin/env bash
# refresh-ssh-keys.sh — re-pull authorized_keys for the andrew user from
# https://github.com/<handle>.keys. Run when a new SSH key is added/removed
# on the GitHub account.
#
# Install on Jinx at /usr/local/bin/refresh-ssh-keys (chmod 0755).
# Run as root (or via sudo).

set -euo pipefail

GITHUB_HANDLE="andrewmcadoo"
LINUX_USER="andrew"
SSH_DIR="/home/${LINUX_USER}/.ssh"

if [[ $EUID -ne 0 ]]; then
    echo "ERROR: must run as root" >&2
    exit 1
fi

tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT

curl -fsSL "https://github.com/${GITHUB_HANDLE}.keys" -o "$tmp"
if [[ ! -s "$tmp" ]]; then
    echo "ERROR: GitHub returned no keys for $GITHUB_HANDLE" >&2
    exit 1
fi

install -m 0600 -o "$LINUX_USER" -g "$LINUX_USER" "$tmp" "${SSH_DIR}/authorized_keys"
echo "Refreshed $(wc -l < "${SSH_DIR}/authorized_keys") key(s) for ${LINUX_USER}"
