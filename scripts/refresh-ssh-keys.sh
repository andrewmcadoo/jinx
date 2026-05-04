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

# Validate that the fetched file looks like a GitHub authorized_keys list
# (every non-blank line begins with a known SSH public-key algorithm).
# Defends against GitHub serving an HTML error page or a CDN rate-limit
# response instead of the keys file.
validate_keys_file() {
    local file="$1"
    [[ -s "$file" ]] || return 1
    if grep -vE '^(ssh-rsa|ssh-ed25519|ecdsa-sha2-nistp(256|384|521)|sk-ssh-ed25519@openssh\.com|sk-ecdsa-sha2-nistp256@openssh\.com)( |$)' "$file" \
         | grep -qE '\S'; then
        return 1
    fi
    return 0
}

tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT

# Mirror bootstrap.sh's 3-attempt retry: GitHub's keys endpoint occasionally
# returns 503 / HTML during incidents, and an unhardened single-shot fetch
# would silently fail or — worse — install a malformed authorized_keys.
for attempt in 1 2 3; do
    if curl -fsSL --max-time 15 "https://github.com/${GITHUB_HANDLE}.keys" -o "$tmp" \
        && validate_keys_file "$tmp"; then
        break
    fi
    echo "Key fetch attempt $attempt failed; sleeping 5s" >&2
    sleep 5
done

if ! validate_keys_file "$tmp"; then
    echo "ERROR: GitHub returned no valid keys for $GITHUB_HANDLE after 3 attempts" >&2
    exit 1
fi

install -m 0600 -o "$LINUX_USER" -g "$LINUX_USER" "$tmp" "${SSH_DIR}/authorized_keys"
echo "Refreshed $(wc -l < "${SSH_DIR}/authorized_keys") key(s) for ${LINUX_USER}"
