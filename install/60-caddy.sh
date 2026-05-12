#!/usr/bin/env bash
# install/60-caddy.sh — install Caddyfile, apex site, apex HTML;
# generate self-signed cert if no real one present; enable caddy.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "${SCRIPT_DIR}/lib.sh"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

CERT=/etc/ssl/jinx/cert.pem
KEY=/etc/ssl/jinx/key.pem

log "Installing Caddyfile and apex site"
install -m 0644 -o root -g root \
    "${REPO_ROOT}/caddy/Caddyfile" /etc/caddy/Caddyfile
install -m 0644 -o root -g root \
    "${REPO_ROOT}/caddy/sites/00-apex.caddy" /etc/caddy/sites/00-apex.caddy

# Apex HTML: install repo copy only if file is absent OR matches the known
# bootstrap placeholder fingerprint. Never clobber an operator-deployed page.
APEX_DEST=/srv/_apex/index.html
APEX_SRC="${REPO_ROOT}/apex/index.html"
PLACEHOLDER_SHA=$(printf '<!doctype html>\n<title>Jinx</title>\n<h1>Jinx is up.</h1>\n<p>Projects will appear here.</p>\n' | sha256sum | awk '{print $1}')
if [[ ! -f "$APEX_DEST" ]]; then
    log "Installing apex index.html (was absent)"
    install -m 0644 -o "$JINX_USER" -g "$JINX_USER" "$APEX_SRC" "$APEX_DEST"
elif [[ "$(sha256sum < "$APEX_DEST" | awk '{print $1}')" == "$PLACEHOLDER_SHA" ]]; then
    log "Installing apex index.html (replacing placeholder)"
    install -m 0644 -o "$JINX_USER" -g "$JINX_USER" "$APEX_SRC" "$APEX_DEST"
else
    log "Preserving operator-deployed apex index.html"
fi

# TLS — preserve real cert, generate self-signed placeholder otherwise.
if [[ -f "$CERT" && -f "$KEY" ]] \
   && openssl x509 -in "$CERT" -noout -checkend 0 >/dev/null 2>&1; then
    log "TLS: existing cert valid, preserving"
else
    log "TLS: generating self-signed placeholder (30-day P-256)"
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 \
        -keyout "$KEY" -out "$CERT" -sha256 -days 30 -nodes \
        -subj "/CN=jinx.generalproducts.io/O=Jinx Self-Signed Placeholder" \
        -addext "subjectAltName=DNS:jinx.generalproducts.io,DNS:*.jinx.generalproducts.io"
    chown root:caddy "$CERT" "$KEY"
    chmod 0644 "$CERT"
    chmod 0640 "$KEY"
fi

log "Validating Caddyfile"
caddy validate --config /etc/caddy/Caddyfile

log "Enabling caddy"
systemctl enable caddy >/dev/null 2>&1 || true
if systemctl is-active --quiet caddy 2>/dev/null; then
    systemctl restart caddy
else
    systemctl start caddy || log "caddy start failed (probably container without systemd PID 1); continuing"
fi
