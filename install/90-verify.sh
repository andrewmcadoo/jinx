#!/usr/bin/env bash
# install/90-verify.sh — assert baseline invariants; exit non-zero on first fail.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "${SCRIPT_DIR}/lib.sh"

fail() { log "FAILED: $*"; exit 1; }
pass() { log "ok: $*"; }

# 1. UFW active.
if ufw status 2>/dev/null | grep -q "Status: active"; then
    pass "ufw active"
else
    log "warn: ufw not reporting active (acceptable in container without iptables)"
fi

# 2. UFW rules for 22 + 443 (skip if ufw inactive).
if ufw status 2>/dev/null | grep -q "Status: active"; then
    ufw status | grep -qE '^22/tcp .*ALLOW' || fail "ufw 22/tcp not allowed"
    ufw status | grep -qE '^443/tcp .*ALLOW' || fail "ufw 443/tcp not allowed"
    pass "ufw allow 22 + 443"
fi

# 3. sshd config syntax.
sshd -t 2>/dev/null || fail "sshd -t failed"
pass "sshd config valid"

# 4. sudoers syntax.
visudo -cf /etc/sudoers.d/00-andrew >/dev/null || fail "sudoers 00-andrew invalid"
pass "sudoers 00-andrew valid"

# 5. Caddyfile syntax.
caddy validate --config /etc/caddy/Caddyfile >/dev/null 2>&1 || fail "caddy validate failed"
pass "caddy config valid"

# 6. caddy service active (best-effort in container).
if systemctl is-active --quiet caddy 2>/dev/null; then
    pass "caddy service active"
else
    log "warn: caddy service not active (acceptable in container without systemd PID 1)"
fi

# 7. Caddy serving HTTPS via the apex site (skip if caddy inactive).
# Use --resolve so SNI matches the configured site block — bare
# `curl https://127.0.0.1/` has no/wrong SNI and Caddy rejects it
# because no site is bound to 127.0.0.1.
if systemctl is-active --quiet caddy 2>/dev/null; then
    code=$(curl -ksI -o /dev/null -w '%{http_code}' --max-time 5 \
        --resolve jinx.generalproducts.io:443:127.0.0.1 \
        https://jinx.generalproducts.io/ || echo "0")
    [[ "$code" == "200" ]] || fail "apex via 127.0.0.1 returned $code (expected 200)"
    pass "caddy serves 200 for apex via 127.0.0.1"
fi

# 8. Disk usage < 90%.
disk=$(df --output=pcent / | tail -1 | tr -dc '0-9')
[[ "$disk" -lt 90 ]] || fail "disk at ${disk}% (>= 90)"
pass "disk at ${disk}%"

# 9. No failed units (skip if systemd is not PID 1).
# `systemctl is-system-running` exits non-zero in `starting`/`degraded`/etc.,
# so gate on the state *name* (stdout), not the exit code, otherwise check 9
# is skipped on first boot while systemd is still settling.
state=$(systemctl is-system-running 2>/dev/null || true)
case "$state" in
    running|degraded|starting|maintenance|initializing)
        failed_count=$(systemctl --failed --no-legend | wc -l)
        [[ "$failed_count" -eq 0 ]] || fail "${failed_count} failed unit(s): $(systemctl --failed --no-legend)"
        pass "no failed units (state=${state})"
        ;;
    *)
        log "warn: systemd not available (state='${state:-unknown}', acceptable in container without systemd PID 1)"
        ;;
esac

# 10. andrew user exists in sudo group.
id "$JINX_USER" >/dev/null 2>&1 || fail "user ${JINX_USER} missing"
id -nG "$JINX_USER" | grep -qw sudo || fail "${JINX_USER} not in sudo group"
pass "${JINX_USER} in sudo group"

# 11. jinx-* helpers installed and executable.
for h in jinx-status jinx-caddy-apply jinx-prune-releases jinx-healthcheck-ping refresh-ssh-keys; do
    [[ -x "/usr/local/bin/${h}" ]] || fail "/usr/local/bin/${h} missing or not executable"
done
pass "helpers installed"

log "all checks passed"
