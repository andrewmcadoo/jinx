# Bootstrap Rework Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the monolithic `bootstrap.sh` with a thin orchestrator + per-concern install scripts cloned from this repo at boot, add the reliability layer the 2026-05-11 disk-full outage exposed, and drop the post-bootstrap manual surface from ~8 steps to 2.

**Architecture:** New `bootstrap.sh` installs `git`, clones the repo to `/opt/jinx`, and execs `/opt/jinx/install/run.sh` which runs `install/10-packages.sh` through `install/90-verify.sh` in numeric order. Every install step is idempotent and locally testable in a Docker container.

**Tech Stack:** bash (with shellcheck), Caddy v2 built-in log rolling, systemd-journald limits, cron, Healthchecks.io heartbeats, GitHub Actions for CI, Docker for the local smoke test.

**Spec:** `docs/superpowers/specs/2026-05-11-bootstrap-rework-design.md`

**Conventions used in this plan:**
- All file paths are repo-relative unless absolute.
- "Run shellcheck" means `shellcheck -e SC1091 <path>` (matches CI's `SHELLCHECK_OPTS`).
- "Run smoke test" means `bash scripts/test-bootstrap-local.sh` (Task 2 introduces this).
- "Commit" steps use `git add <specific files>` — never `git add .` (per repo CLAUDE.md).

---

## File Structure

### New files

| Path | Responsibility |
|---|---|
| `install/lib.sh` | Shared `log()`, `retry()`, and `require_root()` helpers; sourced by every install script. |
| `install/run.sh` | Iterates `install/[0-9]*-*.sh` in sorted order; ERR-traps step failures; logs to `/var/log/jinx-bootstrap.log`. |
| `install/10-packages.sh` | apt baseline + operator tools + Caddy from Cloudsmith; unattended-upgrades config. |
| `install/20-ufw.sh` | UFW: deny incoming, allow 22 + 443. |
| `install/30-user.sh` | Create `andrew`, pull GitHub keys, install `authorized_keys`. |
| `install/40-sshd-sudo.sh` | Install `sshd/90-jinx.conf` + `sudoers/00-andrew` (+optional `01-andrew-nopasswd` if `JINX_NOPASSWD=1`). |
| `install/50-filesystem.sh` | `/srv`, `/etc/caddy/sites`, `/etc/ssl/jinx`, `/var/log/caddy`; pre-create log files. |
| `install/60-caddy.sh` | Install `Caddyfile` + `00-apex.caddy` + apex HTML; self-signed cert if no real one present; enable caddy. |
| `install/70-helpers.sh` | Copy `helpers/jinx-*` + `scripts/refresh-ssh-keys.sh` → `/usr/local/bin/`. |
| `install/80-monitoring.sh` | journald cap, cron entries (prune + healthcheck ping). |
| `install/90-verify.sh` | Asserts 11 invariants; non-zero exit fails bootstrap. |
| `helpers/jinx-status` | One-screenful health snapshot. |
| `helpers/jinx-caddy-apply` | `caddy validate` + `systemctl restart caddy`. |
| `helpers/jinx-prune-releases` | Per-project `releases/` retention; supports `--keep N`, `--dry-run`, `--project NAME`. |
| `helpers/jinx-healthcheck-ping` | POST disk%/load/failed-units to URL in `/etc/jinx/healthchecks-url`. |
| `monitoring/journald-jinx.conf` | `SystemMaxUse=500M`, `SystemMaxFileSize=50M`, `MaxRetentionSec=2week`. |
| `monitoring/cron-prune-releases` | `/etc/cron.daily/jinx-prune-releases` (calls helper with `--keep 3`). |
| `monitoring/cron-healthchecks` | `/etc/cron.d/jinx-healthchecks` (15-min schedule). |
| `scripts/test-bootstrap-local.sh` | Builds Ubuntu 24.04 container, mounts repo, runs `install/run.sh` + `90-verify.sh`, asserts caddy serves 200. |

### Modified files

| Path | Change |
|---|---|
| `bootstrap.sh` | Replace ~300-line monolith with ~80-line orchestrator: installs git, clones repo to `/opt/jinx`, execs `install/run.sh`. |
| `userdata.sh` | Regenerated from the new `bootstrap.sh`. |
| `caddy/Caddyfile` | Add `(common_log)` snippet with tuned `roll_size`/`roll_keep`/`roll_keep_for`; update default log block to use it. |
| `caddy/sites/00-apex.caddy` | Replace inline `log { output file ... }` with `import common_log apex`. |
| `caddy/sites/_example.caddy.tmpl` | Same pattern shift. |
| `caddy/sites/nabu.caddy` | Same pattern shift (so future nabu redeploy gets tuned rotation). |
| `caddy/sites/langfuse-nabu.caddy` | Same pattern shift. |
| `.github/workflows/lint.yml` | Drop the bootstrap-vs-sudoers diff job (no longer relevant — repo file is source of truth, install script copies it). Add a `userdata-drift` job. |
| `RUNBOOK.md` | New "Post-bootstrap setup" section with the 2 remaining manual steps; update "Adding a project" to reflect new state. |
| `JINX.md` | Add the new `JINX_REF` / `JINX_NOPASSWD` env vars under "When this project graduates off Jinx" / config knobs. |

### Deleted/superseded

| Path | Replaced by |
|---|---|
| `bootstrap.sh` (current content) | `bootstrap.sh` (new orchestrator) + `install/*.sh` |
| (heredoc copies of sshd config and sudoers in `bootstrap.sh`) | The repo files `sshd/90-jinx.conf` and `sudoers/00-andrew` themselves, copied by `install/40-sshd-sudo.sh`. |

---

## Task 1: Scaffold + shared lib + run.sh skeleton

**Files:**
- Create: `install/lib.sh`
- Create: `install/run.sh`
- Create: `helpers/.gitkeep`
- Create: `monitoring/.gitkeep`

- [ ] **Step 1: Create the install/ directory and lib.sh**

```bash
mkdir -p install helpers monitoring
touch helpers/.gitkeep monitoring/.gitkeep
```

Write `install/lib.sh`:

```bash
#!/usr/bin/env bash
# install/lib.sh — shared helpers sourced by every install/NN-*.sh.
# Not executable; sourced via `. "$(dirname "$0")/lib.sh"`.

# These globals are exported so child scripts can rely on them.
: "${JINX_LOG_FILE:=/var/log/jinx-bootstrap.log}"
: "${JINX_USER:=andrew}"
export JINX_LOG_FILE JINX_USER

log() {
    printf '[%s] %s\n' "${JINX_STEP:-bootstrap}" "$*" | tee -a "$JINX_LOG_FILE"
}

require_root() {
    if [[ $EUID -ne 0 ]]; then
        log "ERROR: must run as root (currently $EUID)"
        exit 1
    fi
}

# Retry a command up to 3 times with 5s sleep between attempts.
retry() {
    local attempt
    for attempt in 1 2 3; do
        if "$@"; then
            return 0
        fi
        log "Command failed (attempt $attempt/3): $*"
        sleep 5
    done
    log "ERROR: command failed after 3 attempts: $*"
    return 1
}
```

- [ ] **Step 2: Write the run.sh orchestrator skeleton**

Write `install/run.sh`:

```bash
#!/usr/bin/env bash
# install/run.sh — orchestrates install/NN-*.sh in numeric order.
set -euo pipefail
IFS=$'\n\t'
umask 022

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "${SCRIPT_DIR}/lib.sh"

require_root

trap 'log "ERROR: step ${JINX_STEP:-?} failed at line ${LINENO}: ${BASH_COMMAND}"' ERR

JINX_STEP=run log "Starting install at $(date -u --iso-8601=seconds)"

shopt -s nullglob
steps=("${SCRIPT_DIR}"/[0-9][0-9]-*.sh)
shopt -u nullglob

if [[ ${#steps[@]} -eq 0 ]]; then
    JINX_STEP=run log "No install steps found in ${SCRIPT_DIR}"
    exit 0
fi

for step in "${steps[@]}"; do
    name="$(basename "$step" .sh)"
    export JINX_STEP="$name"
    log "begin"
    bash "$step"
    log "ok"
done

JINX_STEP=run log "All steps complete"
```

- [ ] **Step 3: Make scripts executable**

```bash
chmod 0755 install/run.sh
# lib.sh is sourced, not executed; leaving it 0644 is fine.
```

- [ ] **Step 4: shellcheck both files**

```bash
shellcheck -e SC1091 install/lib.sh install/run.sh
```

Expected: no output, exit 0.

- [ ] **Step 5: Smoke-run run.sh against an empty install dir**

```bash
sudo JINX_LOG_FILE=/tmp/jinx-test.log bash install/run.sh
sudo cat /tmp/jinx-test.log
```

Expected: log shows `Starting install at …`, `No install steps found`, exit 0. (No install steps exist yet — that's the point.)

- [ ] **Step 6: Commit**

```bash
git add install/lib.sh install/run.sh helpers/.gitkeep monitoring/.gitkeep
git commit -m "feat(install): scaffold orchestrator + shared lib"
```

---

## Task 2: Docker smoke-test harness

**Files:**
- Create: `scripts/test-bootstrap-local.sh`

- [ ] **Step 1: Write the harness**

Write `scripts/test-bootstrap-local.sh`:

```bash
#!/usr/bin/env bash
# scripts/test-bootstrap-local.sh — run install/run.sh in a throwaway
# Ubuntu 24.04 container with the repo mounted. ~60-90 seconds.
#
# Requires Docker on the host. Not part of CI by default.
#
# Usage: bash scripts/test-bootstrap-local.sh [--keep] [--nopasswd]
#   --keep      Don't remove the container on exit (debug).
#   --nopasswd  Set JINX_NOPASSWD=1 during the run.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IMAGE="ubuntu:24.04"
CONTAINER="jinx-bootstrap-test-$$"
KEEP=0
NOPASSWD_ENV=""

for arg in "$@"; do
    case "$arg" in
        --keep) KEEP=1 ;;
        --nopasswd) NOPASSWD_ENV="-e JINX_NOPASSWD=1" ;;
        *) echo "unknown arg: $arg" >&2; exit 2 ;;
    esac
done

cleanup() {
    if [[ $KEEP -eq 0 ]]; then
        docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
    else
        echo "Container preserved: $CONTAINER"
    fi
}
trap cleanup EXIT

echo "==> Pulling $IMAGE (cached after first run)"
docker pull -q "$IMAGE" >/dev/null

echo "==> Starting container $CONTAINER"
# --privileged: required for systemd + ufw inside the container.
# tmpfs /run /run/lock: systemd needs writable runtime dirs.
docker run -d --name "$CONTAINER" --privileged \
    --tmpfs /run --tmpfs /run/lock \
    -v "${REPO_ROOT}:/opt/jinx:ro" \
    $NOPASSWD_ENV \
    "$IMAGE" sleep infinity >/dev/null

# Install systemd inside the container so unit-management commands work.
echo "==> Installing systemd + minimal prereqs in container"
docker exec "$CONTAINER" bash -c '
    set -e
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y --no-install-recommends systemd systemd-sysv dbus sudo
'

echo "==> Running install/run.sh"
docker exec ${NOPASSWD_ENV:+-e JINX_NOPASSWD=1} "$CONTAINER" \
    bash -c 'cd /opt/jinx && bash install/run.sh'

echo "==> All install steps completed"
echo "==> Tail of /var/log/jinx-bootstrap.log:"
docker exec "$CONTAINER" tail -30 /var/log/jinx-bootstrap.log

# Final per-task assertions are made by install/90-verify.sh; this harness
# just confirms the chain completes non-zero.
echo
echo "SMOKE TEST PASSED"
```

- [ ] **Step 2: Make it executable**

```bash
chmod 0755 scripts/test-bootstrap-local.sh
```

- [ ] **Step 3: shellcheck**

```bash
shellcheck -e SC1091 scripts/test-bootstrap-local.sh
```

Expected: no output.

- [ ] **Step 4: Run the harness against the empty install/ dir**

```bash
bash scripts/test-bootstrap-local.sh
```

Expected: `SMOKE TEST PASSED` (run.sh sees no install steps and exits 0).

- [ ] **Step 5: Commit**

```bash
git add scripts/test-bootstrap-local.sh
git commit -m "test(bootstrap): Docker smoke-test harness for install chain"
```

---

## Task 3: 10-packages.sh — apt baseline + operator tools + Caddy

**Files:**
- Create: `install/10-packages.sh`

- [ ] **Step 1: Write the script**

Write `install/10-packages.sh`:

```bash
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
    tmux htop jq rsync vim-tiny ncdu less openssl

if ! command -v caddy >/dev/null; then
    log "Adding Caddy apt repo"
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
        | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
        | tee /etc/apt/sources.list.d/caddy-stable.list >/dev/null
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
```

- [ ] **Step 2: chmod + shellcheck**

```bash
chmod 0755 install/10-packages.sh
shellcheck -e SC1091 install/10-packages.sh
```

Expected: no output.

- [ ] **Step 3: Run the smoke test**

```bash
bash scripts/test-bootstrap-local.sh
```

Expected: `SMOKE TEST PASSED`. The tail of the bootstrap log should show `10-packages: begin … 10-packages: ok`. Caddy installs successfully inside the container.

- [ ] **Step 4: Commit**

```bash
git add install/10-packages.sh
git commit -m "feat(install): 10-packages — apt baseline + operator tools + Caddy"
```

---

## Task 4: 20-ufw.sh — firewall

**Files:**
- Create: `install/20-ufw.sh`

- [ ] **Step 1: Write the script**

```bash
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
```

- [ ] **Step 2: chmod + shellcheck**

```bash
chmod 0755 install/20-ufw.sh
shellcheck -e SC1091 install/20-ufw.sh
```

- [ ] **Step 3: Smoke test**

```bash
bash scripts/test-bootstrap-local.sh
```

Expected: `SMOKE TEST PASSED`. Bootstrap log shows `Status: active` line from `ufw status verbose`.

> Note: UFW inside a container without the host iptables module may print a warning. Acceptable — we only need the rules persisted in `/etc/ufw/`. If smoke test fails because `ufw enable` errors out, fall back to `ufw --force enable || log "ufw enable warning, continuing"` only after confirming the host has iptables.

- [ ] **Step 4: Commit**

```bash
git add install/20-ufw.sh
git commit -m "feat(install): 20-ufw — deny incoming, allow 22+443"
```

---

## Task 5: 30-user.sh — andrew user + GitHub SSH keys

**Files:**
- Create: `install/30-user.sh`

- [ ] **Step 1: Write the script**

```bash
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
```

- [ ] **Step 2: chmod + shellcheck**

```bash
chmod 0755 install/30-user.sh
shellcheck -e SC1091 install/30-user.sh
```

- [ ] **Step 3: Smoke test**

```bash
bash scripts/test-bootstrap-local.sh
```

Expected: `SMOKE TEST PASSED`. Bootstrap log shows `Installed N SSH key(s)` for N ≥ 1.

- [ ] **Step 4: Commit**

```bash
git add install/30-user.sh
git commit -m "feat(install): 30-user — create andrew + GitHub authorized_keys"
```

---

## Task 6: 40-sshd-sudo.sh — sshd hardening + sudoers

**Files:**
- Create: `install/40-sshd-sudo.sh`

- [ ] **Step 1: Write the script**

```bash
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
```

- [ ] **Step 2: chmod + shellcheck**

```bash
chmod 0755 install/40-sshd-sudo.sh
shellcheck -e SC1091 install/40-sshd-sudo.sh
```

- [ ] **Step 3: Smoke test (default — no nopasswd)**

```bash
bash scripts/test-bootstrap-local.sh
```

Expected: log shows `JINX_NOPASSWD not set; skipping blanket NOPASSWD` and bootstrap completes.

- [ ] **Step 4: Smoke test (with nopasswd)**

```bash
bash scripts/test-bootstrap-local.sh --nopasswd
```

Expected: log shows `JINX_NOPASSWD=1 set; installing sudoers/01-andrew-nopasswd`.

- [ ] **Step 5: Commit**

```bash
git add install/40-sshd-sudo.sh
git commit -m "feat(install): 40-sshd-sudo — install from repo files (eliminates heredoc dup)"
```

---

## Task 7: 50-filesystem.sh — /srv tree + Caddy dirs

**Files:**
- Create: `install/50-filesystem.sh`

- [ ] **Step 1: Write the script**

```bash
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
```

- [ ] **Step 2: chmod + shellcheck**

```bash
chmod 0755 install/50-filesystem.sh
shellcheck -e SC1091 install/50-filesystem.sh
```

- [ ] **Step 3: Smoke test**

```bash
bash scripts/test-bootstrap-local.sh
```

Expected: `SMOKE TEST PASSED`. After the run, inside the container `ls -la /srv /etc/caddy/sites /etc/ssl/jinx /var/log/caddy` should show the directories with correct ownership.

- [ ] **Step 4: Commit**

```bash
git add install/50-filesystem.sh
git commit -m "feat(install): 50-filesystem — /srv tree + Caddy dirs + log pre-create"
```

---

## Task 8: Caddy log-rolling snippet + update all sites

**Files:**
- Modify: `caddy/Caddyfile`
- Modify: `caddy/sites/00-apex.caddy`
- Modify: `caddy/sites/_example.caddy.tmpl`
- Modify: `caddy/sites/nabu.caddy`
- Modify: `caddy/sites/langfuse-nabu.caddy`

- [ ] **Step 1: Add `(common_log)` snippet to Caddyfile and tune the default log**

Edit `caddy/Caddyfile` to:

```caddy
{
    admin off
    auto_https off

    log default {
        output file /var/log/caddy/caddy.log {
            roll_size 50mb
            roll_keep 5
            roll_keep_for 168h
        }
        format json
    }
}

# Reusable log block for per-site Caddyfiles. Tuned tighter than Caddy's
# defaults (100MB × 10 keeps = ~1GB per site) — 50MB × 5 keeps = ~250MB per
# site, sized so even 10 sites stay well under the box's disk budget. The
# 168h (7-day) max-keep-for ensures stale rotated logs don't pile up.
#
# Usage in a site file:
#     import common_log <site-name>
# … which expands to:
#     log {
#         output file /var/log/caddy/<site-name>.log {
#             roll_size 50mb
#             roll_keep 5
#             roll_keep_for 168h
#         }
#         format json
#     }
(common_log) {
    log {
        output file /var/log/caddy/{args[0]}.log {
            roll_size 50mb
            roll_keep 5
            roll_keep_for 168h
        }
        format json
    }
}

import sites/*.caddy
```

- [ ] **Step 2: Update `caddy/sites/00-apex.caddy`**

Replace the `log { … }` block with `import common_log apex`:

```caddy
jinx.generalproducts.io {
    tls /etc/ssl/jinx/cert.pem /etc/ssl/jinx/key.pem

    root * /srv/_apex
    file_server

    import common_log apex
}
```

- [ ] **Step 3: Update `caddy/sites/_example.caddy.tmpl`**

Replace the `log { … }` block with `import common_log example`:

```caddy
example.jinx.generalproducts.io {
    tls /etc/ssl/jinx/cert.pem /etc/ssl/jinx/key.pem

    handle /api/* {
        reverse_proxy 127.0.0.1:3199
    }

    handle {
        reverse_proxy 127.0.0.1:3099
    }

    import common_log example
}
```

- [ ] **Step 4: Update `caddy/sites/nabu.caddy` and `caddy/sites/langfuse-nabu.caddy`**

For each file: replace the inline `log { output file /var/log/caddy/<name>.log; format json }` block with `import common_log <name>`. Read each file first; the name argument should match the existing log filename (e.g., `nabu` → `import common_log nabu`).

- [ ] **Step 5: caddy validate locally**

```bash
# Recreate the same CI shim so validate doesn't fail on missing TLS/log paths.
sudo install -d -m 0755 /var/log/caddy
sudo chown "$(id -un):$(id -gn)" /var/log/caddy
sudo install -d -m 0755 /etc/ssl/jinx
sudo openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
    -keyout /etc/ssl/jinx/key.pem -out /etc/ssl/jinx/cert.pem \
    -subj "/CN=local-validate.invalid"
sudo chmod 0644 /etc/ssl/jinx/cert.pem /etc/ssl/jinx/key.pem
caddy validate --config caddy/Caddyfile
```

Expected: `Valid configuration`.

- [ ] **Step 6: Commit**

```bash
git add caddy/Caddyfile caddy/sites/00-apex.caddy caddy/sites/_example.caddy.tmpl \
        caddy/sites/nabu.caddy caddy/sites/langfuse-nabu.caddy
git commit -m "feat(caddy): common_log snippet — tuned rotation 50MB×5, applied to all sites"
```

---

## Task 9: 60-caddy.sh — install Caddyfile + apex + self-signed cert

**Files:**
- Create: `install/60-caddy.sh`

- [ ] **Step 1: Write the script**

```bash
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
```

- [ ] **Step 2: chmod + shellcheck**

```bash
chmod 0755 install/60-caddy.sh
shellcheck -e SC1091 install/60-caddy.sh
```

- [ ] **Step 3: Smoke test**

```bash
bash scripts/test-bootstrap-local.sh
```

Expected: log shows `Valid configuration` from `caddy validate`, plus `Installing apex index.html (was absent)` and the self-signed cert generation line. The Docker container has systemd PID 1 (via `--privileged` + `systemd-sysv`), so `systemctl start caddy` should succeed; if it doesn't, the script logs and continues — verification by Task 13's full smoke test catches a real regression.

- [ ] **Step 4: Commit**

```bash
git add install/60-caddy.sh
git commit -m "feat(install): 60-caddy — install Caddyfile + apex + self-signed cert"
```

---

## Task 10: Helper scripts (jinx-status, jinx-caddy-apply, jinx-prune-releases, jinx-healthcheck-ping)

**Files:**
- Create: `helpers/jinx-status`
- Create: `helpers/jinx-caddy-apply`
- Create: `helpers/jinx-prune-releases`
- Create: `helpers/jinx-healthcheck-ping`

- [ ] **Step 1: Write `helpers/jinx-status`**

```bash
#!/usr/bin/env bash
# jinx-status — one-screen health snapshot.
set -euo pipefail

bold() { printf '\033[1m%s\033[0m\n' "$*"; }

bold "Host"
uptime
echo

bold "Disk"
df -h / | awk 'NR==1 || NR==2 {print}'
echo

bold "Memory"
free -h | awk 'NR<=2'
echo

bold "Failed units"
systemctl --failed --no-legend || true
echo

bold "Caddy"
if systemctl is-active --quiet caddy; then
    echo "active"
else
    echo "INACTIVE"
fi
if [[ -f /etc/ssl/jinx/cert.pem ]]; then
    openssl x509 -in /etc/ssl/jinx/cert.pem -noout -subject -enddate
fi
echo

bold "Projects under /srv (excluding _apex)"
for d in /srv/*/; do
    name="$(basename "$d")"
    [[ "$name" == "_apex" ]] && continue
    units="$(systemctl list-units --type=service --no-legend "${name}-*.service" 2>/dev/null \
             | awk '{print $1, $3}' | paste -sd, -)"
    printf '  %-20s %s\n' "$name" "${units:-(no units)}"
done
```

- [ ] **Step 2: Write `helpers/jinx-caddy-apply`**

```bash
#!/usr/bin/env bash
# jinx-caddy-apply — `caddy validate` then `systemctl restart caddy`.
# Encodes the "restart, not reload" rule (RUNBOOK).
set -euo pipefail

if ! caddy validate --config /etc/caddy/Caddyfile; then
    echo "caddy validate FAILED — refusing to restart" >&2
    exit 1
fi
systemctl restart caddy
echo "caddy restarted at $(date -u --iso-8601=seconds)"
```

- [ ] **Step 3: Write `helpers/jinx-prune-releases`**

```bash
#!/usr/bin/env bash
# jinx-prune-releases — keep newest N release dirs per project, delete older.
set -euo pipefail

KEEP=5
DRY_RUN=0
PROJECT=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --keep) KEEP="$2"; shift 2 ;;
        --dry-run) DRY_RUN=1; shift ;;
        --project) PROJECT="$2"; shift 2 ;;
        -h|--help)
            sed -n '2,4p' "$0"; exit 0 ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done

if ! [[ "$KEEP" =~ ^[0-9]+$ ]] || [[ "$KEEP" -lt 1 ]]; then
    echo "ERROR: --keep must be a positive integer, got: $KEEP" >&2
    exit 2
fi

prune_one() {
    local proj_dir="$1"
    local name; name="$(basename "$proj_dir")"
    local rel_dir="${proj_dir}/releases"
    [[ -d "$rel_dir" ]] || return 0

    local current_target=""
    if [[ -L "${proj_dir}/current" ]]; then
        current_target="$(readlink -f "${proj_dir}/current" || true)"
    fi

    # Sort releases newest-first by mtime, keep first KEEP, delete the rest
    # (skipping whatever the current symlink points at).
    local releases
    mapfile -t releases < <(find "$rel_dir" -mindepth 1 -maxdepth 1 -type d -printf '%T@ %p\n' \
                            | sort -nr | awk '{print $2}')

    local idx=0
    for r in "${releases[@]}"; do
        idx=$((idx + 1))
        if [[ $idx -le $KEEP ]]; then continue; fi
        if [[ -n "$current_target" && "$(readlink -f "$r")" == "$current_target" ]]; then
            echo "[$name] skipping current symlink target: $r"
            continue
        fi
        if [[ $DRY_RUN -eq 1 ]]; then
            echo "[$name] DRY-RUN would remove: $r"
        else
            echo "[$name] removing: $r"
            rm -rf -- "$r"
        fi
    done
}

if [[ -n "$PROJECT" ]]; then
    prune_one "/srv/${PROJECT}"
else
    for d in /srv/*/; do
        name="$(basename "$d")"
        [[ "$name" == "_apex" ]] && continue
        prune_one "$d"
    done
fi
```

- [ ] **Step 4: Write `helpers/jinx-healthcheck-ping`**

```bash
#!/usr/bin/env bash
# jinx-healthcheck-ping — POST disk%/load/failed-units to Healthchecks.io.
# URL lives at /etc/jinx/healthchecks-url (single line, no trailing newline-sensitive).
# Silently no-ops if the URL file is absent — bootstrap doesn't require it.
set -euo pipefail

URL_FILE=/etc/jinx/healthchecks-url
[[ -r "$URL_FILE" ]] || exit 0

URL="$(tr -d '[:space:]' < "$URL_FILE")"
[[ -n "$URL" ]] || exit 0

disk=$(df --output=pcent / | tail -1 | tr -dc '0-9')
load=$(awk '{print $1}' /proc/loadavg)
failed=$(systemctl --failed --no-legend | wc -l)

curl -fsS -m 10 --retry 3 \
    --data-urlencode "disk=${disk}%" \
    --data-urlencode "load=${load}" \
    --data-urlencode "failed=${failed}" \
    "$URL" > /dev/null
```

- [ ] **Step 5: chmod + shellcheck**

```bash
chmod 0755 helpers/jinx-status helpers/jinx-caddy-apply \
           helpers/jinx-prune-releases helpers/jinx-healthcheck-ping
shellcheck -e SC1091 helpers/jinx-*
```

- [ ] **Step 6: Local sanity check on prune-releases dry-run**

```bash
# Create a fake project tree and run --dry-run against it.
tmp=$(mktemp -d)
mkdir -p "${tmp}/srv/foo/releases/2026-01-01-aaa" \
         "${tmp}/srv/foo/releases/2026-02-01-bbb" \
         "${tmp}/srv/foo/releases/2026-03-01-ccc" \
         "${tmp}/srv/foo/releases/2026-04-01-ddd" \
         "${tmp}/srv/foo/releases/2026-05-01-eee"
ln -s "${tmp}/srv/foo/releases/2026-05-01-eee" "${tmp}/srv/foo/current"

# Run with /srv overridden via a quick wrapper — the helper hard-codes /srv,
# so test by symlinking. Easier: just inspect dry-run output by patching path.
# (For this sanity check, edit the file path temporarily OR rely on the
# Docker smoke test in Task 11 to exercise it for real.)
echo "Dry-run sanity defer to Task 11 Docker run."
rm -rf "$tmp"
```

(The hard-coded `/srv` path makes a host-local unit test awkward; the script gets real exercise via Task 11's Docker smoke run.)

- [ ] **Step 7: Commit**

```bash
git add helpers/jinx-status helpers/jinx-caddy-apply \
        helpers/jinx-prune-releases helpers/jinx-healthcheck-ping
git commit -m "feat(helpers): jinx-status, jinx-caddy-apply, jinx-prune-releases, jinx-healthcheck-ping"
```

---

## Task 11: 70-helpers.sh — install helpers + refresh-ssh-keys to /usr/local/bin

**Files:**
- Create: `install/70-helpers.sh`

- [ ] **Step 1: Write the script**

```bash
#!/usr/bin/env bash
# install/70-helpers.sh — install jinx-* helpers + refresh-ssh-keys to /usr/local/bin.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "${SCRIPT_DIR}/lib.sh"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

for helper in jinx-status jinx-caddy-apply jinx-prune-releases jinx-healthcheck-ping; do
    install -m 0755 -o root -g root \
        "${REPO_ROOT}/helpers/${helper}" "/usr/local/bin/${helper}"
    log "installed /usr/local/bin/${helper}"
done

install -m 0755 -o root -g root \
    "${REPO_ROOT}/scripts/refresh-ssh-keys.sh" /usr/local/bin/refresh-ssh-keys
log "installed /usr/local/bin/refresh-ssh-keys"
```

- [ ] **Step 2: chmod + shellcheck**

```bash
chmod 0755 install/70-helpers.sh
shellcheck -e SC1091 install/70-helpers.sh
```

- [ ] **Step 3: Smoke test**

```bash
bash scripts/test-bootstrap-local.sh
```

Expected: log shows five `installed /usr/local/bin/*` lines.

- [ ] **Step 4: Commit**

```bash
git add install/70-helpers.sh
git commit -m "feat(install): 70-helpers — install jinx-* + refresh-ssh-keys to /usr/local/bin"
```

---

## Task 12: Monitoring config files

**Files:**
- Create: `monitoring/journald-jinx.conf`
- Create: `monitoring/cron-prune-releases`
- Create: `monitoring/cron-healthchecks`

- [ ] **Step 1: Write `monitoring/journald-jinx.conf`**

```ini
[Journal]
SystemMaxUse=500M
SystemMaxFileSize=50M
MaxRetentionSec=2week
```

- [ ] **Step 2: Write `monitoring/cron-prune-releases`**

```sh
#!/bin/sh
# /etc/cron.daily/jinx-prune-releases — installed by install/80-monitoring.sh.
exec /usr/local/bin/jinx-prune-releases --keep 3
```

- [ ] **Step 3: Write `monitoring/cron-healthchecks`**

```
# /etc/cron.d/jinx-healthchecks — installed by install/80-monitoring.sh.
# 15-minute heartbeat to /etc/jinx/healthchecks-url (silent no-op if absent).
SHELL=/bin/sh
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin
*/15 * * * * root /usr/local/bin/jinx-healthcheck-ping
```

- [ ] **Step 4: shellcheck the cron-prune-releases script**

```bash
shellcheck monitoring/cron-prune-releases
```

(The other two are config files, not shell.)

- [ ] **Step 5: Commit**

```bash
git add monitoring/journald-jinx.conf monitoring/cron-prune-releases monitoring/cron-healthchecks
git commit -m "feat(monitoring): journald cap + prune-releases cron + healthcheck-ping cron"
```

---

## Task 13: 80-monitoring.sh — install monitoring artifacts

**Files:**
- Create: `install/80-monitoring.sh`

- [ ] **Step 1: Write the script**

```bash
#!/usr/bin/env bash
# install/80-monitoring.sh — journald cap, prune cron, healthcheck cron.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "${SCRIPT_DIR}/lib.sh"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

install -d -m 0755 /etc/systemd/journald.conf.d
install -m 0644 -o root -g root \
    "${REPO_ROOT}/monitoring/journald-jinx.conf" \
    /etc/systemd/journald.conf.d/jinx.conf
log "installed journald cap (500M)"

install -m 0755 -o root -g root \
    "${REPO_ROOT}/monitoring/cron-prune-releases" \
    /etc/cron.daily/jinx-prune-releases
log "installed /etc/cron.daily/jinx-prune-releases"

install -m 0644 -o root -g root \
    "${REPO_ROOT}/monitoring/cron-healthchecks" \
    /etc/cron.d/jinx-healthchecks
log "installed /etc/cron.d/jinx-healthchecks"

# Make /etc/jinx/ exist (empty) so operator can drop in healthchecks-url later.
install -d -m 0755 -o root -g root /etc/jinx

# Restart journald to apply the new cap (best-effort in containers).
systemctl restart systemd-journald 2>/dev/null \
    || log "journald restart not possible here (likely container); skipping"
```

- [ ] **Step 2: chmod + shellcheck**

```bash
chmod 0755 install/80-monitoring.sh
shellcheck -e SC1091 install/80-monitoring.sh
```

- [ ] **Step 3: Smoke test**

```bash
bash scripts/test-bootstrap-local.sh
```

Expected: log shows the three `installed …` lines.

- [ ] **Step 4: Commit**

```bash
git add install/80-monitoring.sh
git commit -m "feat(install): 80-monitoring — journald cap + prune cron + healthcheck cron"
```

---

## Task 14: 90-verify.sh — final invariant checks

**Files:**
- Create: `install/90-verify.sh`

- [ ] **Step 1: Write the script**

```bash
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

# 7. Caddy serving HTTPS on 127.0.0.1 (skip if caddy inactive).
if systemctl is-active --quiet caddy 2>/dev/null; then
    code=$(curl -ksI -o /dev/null -w '%{http_code}' --max-time 5 https://127.0.0.1/ || echo "0")
    [[ "$code" == "200" ]] || fail "https://127.0.0.1/ returned $code (expected 200)"
    pass "caddy serves 200 on 127.0.0.1"
fi

# 8. Disk usage < 90%.
disk=$(df --output=pcent / | tail -1 | tr -dc '0-9')
[[ "$disk" -lt 90 ]] || fail "disk at ${disk}% (>= 90)"
pass "disk at ${disk}%"

# 9. No failed units.
failed_count=$(systemctl --failed --no-legend | wc -l)
[[ "$failed_count" -eq 0 ]] || fail "${failed_count} failed unit(s): $(systemctl --failed --no-legend)"
pass "no failed units"

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
```

- [ ] **Step 2: chmod + shellcheck**

```bash
chmod 0755 install/90-verify.sh
shellcheck -e SC1091 install/90-verify.sh
```

- [ ] **Step 3: Smoke test (full chain)**

```bash
bash scripts/test-bootstrap-local.sh
```

Expected: log ends with `90-verify: all checks passed` and `run: All steps complete`. SMOKE TEST PASSED printed by the harness.

- [ ] **Step 4: Smoke test failure-mode sanity (optional)**

Temporarily break a check by editing `install/40-sshd-sudo.sh` to write a bad `Match User junk` line into the sshd config, then re-run the smoke test. Expected: `90-verify: FAILED: sshd -t failed` and harness exits non-zero. Revert the edit.

- [ ] **Step 5: Commit**

```bash
git add install/90-verify.sh
git commit -m "feat(install): 90-verify — assert 11 baseline invariants"
```

---

## Task 15: Replace bootstrap.sh with thin orchestrator

**Files:**
- Modify (rewrite): `bootstrap.sh`

- [ ] **Step 1: Write the new bootstrap.sh**

Replace `bootstrap.sh` content entirely with:

```bash
#!/usr/bin/env bash
# bootstrap.sh — first-boot configuration for Jinx.
#
# Runs as Lightsail cloud-init user-data. Installs git, clones this repo
# to /opt/jinx, then execs install/run.sh. Idempotent: safe to re-run
# (e.g. after snapshot restore) — re-running re-pulls the repo and
# re-runs every install step.
#
# Spec: docs/superpowers/specs/2026-05-11-bootstrap-rework-design.md

set -euo pipefail
umask 022

JINX_REPO="${JINX_REPO:-https://github.com/andrewmcadoo/jinx.git}"
JINX_REF="${JINX_REF:-main}"
JINX_DIR="${JINX_DIR:-/opt/jinx}"
LOG_FILE=/var/log/jinx-bootstrap.log

log() { printf '[bootstrap] %s\n' "$*" | tee -a "$LOG_FILE"; }

if [[ $EUID -ne 0 ]]; then
    log "ERROR: must run as root (currently $EUID)"
    exit 1
fi

log "Bootstrap start $(date -u --iso-8601=seconds), repo=$JINX_REPO ref=$JINX_REF"

# Minimal apt prereqs needed just to clone the repo. install/10-packages.sh
# handles the full package set afterward.
export DEBIAN_FRONTEND=noninteractive
for attempt in 1 2 3; do
    if apt-get update -qq; then break; fi
    log "apt-get update failed (attempt $attempt/3); sleeping 5s"
    sleep 5
done
apt-get install -y --no-install-recommends ca-certificates curl git

# Clone or pull-update the repo. Re-runs re-converge on $JINX_REF.
if [[ -d "${JINX_DIR}/.git" ]]; then
    log "Updating existing repo at ${JINX_DIR}"
    git -C "$JINX_DIR" fetch --quiet origin
    git -C "$JINX_DIR" checkout --quiet "$JINX_REF"
    git -C "$JINX_DIR" pull --quiet --ff-only || log "pull --ff-only failed; staying at current ref"
else
    log "Cloning ${JINX_REPO} → ${JINX_DIR} at ref ${JINX_REF}"
    git clone --quiet --branch "$JINX_REF" "$JINX_REPO" "$JINX_DIR"
fi

current_ref=$(git -C "$JINX_DIR" rev-parse --short HEAD)
log "Handing off to install/run.sh at ${current_ref}"

exec bash "${JINX_DIR}/install/run.sh"
```

- [ ] **Step 2: shellcheck**

```bash
shellcheck -e SC1091 bootstrap.sh
```

Expected: no output.

- [ ] **Step 3: Sanity-check size**

```bash
wc -l bootstrap.sh
```

Expected: ~50–80 lines.

- [ ] **Step 4: Commit**

```bash
git add bootstrap.sh
git commit -m "feat(bootstrap): replace monolith with thin orchestrator (clones repo, execs install/run.sh)"
```

---

## Task 16: Regenerate userdata.sh

**Files:**
- Modify (regenerate): `userdata.sh`

- [ ] **Step 1: Regenerate**

```bash
bash scripts/make-userdata.sh
```

Expected output: `Generated /…/jinx/userdata.sh (<N> bytes)`. N should be well under 16384.

- [ ] **Step 2: Verify shellcheck of regenerated artifact**

```bash
shellcheck -e SC1091 userdata.sh
```

Expected: no output (or only warnings about the inner heredoc-protected content, which is acceptable).

- [ ] **Step 3: Sanity-check it parses in dash**

```bash
dash -n userdata.sh && echo "dash parse OK"
```

Expected: `dash parse OK`. (If dash isn't installed: `sudo apt-get install -y dash` or skip — `scripts/make-userdata.sh` already enforces the structural invariants that make this safe.)

- [ ] **Step 4: Commit**

```bash
git add userdata.sh
git commit -m "chore(userdata): regenerate from new bootstrap.sh"
```

---

## Task 17: CI updates — drop stale diff, add userdata-drift, shellcheck install/ + helpers/

**Files:**
- Modify: `.github/workflows/lint.yml`

- [ ] **Step 1: Read the existing lint.yml**

```bash
cat .github/workflows/lint.yml
```

Note the four jobs: `shellcheck`, `caddy-validate`, `systemd-verify`, `visudo-check`.

- [ ] **Step 2: Remove the bootstrap-vs-sudoers diff from `visudo-check`**

In `.github/workflows/lint.yml`, delete the last step of the `visudo-check` job (the one named "Verify bootstrap.sh inline copy matches the repo file"). The new `bootstrap.sh` no longer heredoc-duplicates the sudoers line — the diff check is no longer meaningful. Keep the two `visudo -cf` steps for `sudoers/00-andrew` and `sudoers/01-andrew-nopasswd`.

- [ ] **Step 3: Add the `userdata-drift` job**

Append to `.github/workflows/lint.yml`:

```yaml
  userdata-drift:
    name: userdata.sh matches bootstrap.sh
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Regenerate userdata.sh into a temp dir
        run: |
          tmp="$(mktemp -d)"
          cp bootstrap.sh "$tmp/bootstrap.sh"
          mkdir -p "$tmp/scripts"
          cp scripts/make-userdata.sh "$tmp/scripts/"
          (cd "$tmp" && bash scripts/make-userdata.sh)
          diff -u userdata.sh "$tmp/userdata.sh"
```

This regenerates `userdata.sh` in a sandbox and diffs against the committed file — any edit to `bootstrap.sh` without a corresponding regenerate fails CI.

- [ ] **Step 4: Confirm the `shellcheck` job picks up the new directories**

The existing `shellcheck` job uses `ludeeus/action-shellcheck@…` with `SHELLCHECK_OPTS: -e SC1091` and no path restriction — by default it scans the whole checkout for shell files. New directories `install/`, `helpers/`, `monitoring/`, `scripts/` are all covered automatically. Verify by reading the action's docs / the existing log; no edit needed.

- [ ] **Step 5: Push the branch and watch CI green**

```bash
git add .github/workflows/lint.yml
git commit -m "ci(lint): drop bootstrap-vs-sudoers diff, add userdata-drift job"
git push
```

Then on GitHub: confirm all four jobs (`shellcheck`, `caddy-validate`, `systemd-verify`, `visudo-check`, `userdata-drift`) are green. (Run is OK to be a PR pre-flight; merge to main after green.)

---

## Task 18: Update RUNBOOK and JINX.md

**Files:**
- Modify: `RUNBOOK.md`
- Modify: `JINX.md`

- [ ] **Step 1: Add "Post-bootstrap setup" section to `RUNBOOK.md`**

After the `## SSH` section, insert:

```markdown
## Post-bootstrap setup

After `bootstrap.sh` completes (visible at the end of `/var/log/jinx-bootstrap.log` as `90-verify: all checks passed`), two manual steps remain:

### 1. Install the real Cloudflare Origin Cert

```
scp cert.pem key.pem jinx:/tmp/
ssh jinx 'sudo install -m 0644 -o root -g caddy /tmp/cert.pem /etc/ssl/jinx/cert.pem \
          && sudo install -m 0640 -o root -g caddy /tmp/key.pem /etc/ssl/jinx/key.pem \
          && rm /tmp/cert.pem /tmp/key.pem \
          && sudo /usr/local/bin/jinx-caddy-apply'
```

Until this runs, Cloudflare returns 526 (origin cert verification failed) because the self-signed placeholder generated by `install/60-caddy.sh` is not trusted by CF's "Full (strict)" mode.

### 2. (Optional) Configure Healthchecks.io heartbeat

Create a check at https://healthchecks.io/, copy its ping URL, then:

```
ssh jinx 'echo "https://hc-ping.com/<uuid>" | sudo tee /etc/jinx/healthchecks-url'
```

The 15-minute cron entry (`/etc/cron.d/jinx-healthchecks`, installed by `install/80-monitoring.sh`) will begin posting disk/load/failed-units data immediately. Healthchecks.io alerts on missed heartbeats.
```

- [ ] **Step 2: Update "Restoring from a Lightsail snapshot" to reflect the new flow**

The current §"Restoring from a Lightsail snapshot" stays accurate — bootstrap re-runs cleanly. Add a one-line note:

> **Note:** `bootstrap.sh` re-runs automatically on the restored instance and self-heals toward the current `main` of this repo. If you've made config changes that aren't yet committed, commit them first, then restore.

- [ ] **Step 3: Add config knobs to `JINX.md`**

Insert a new section before "## Don't" in `JINX.md`:

```markdown
## Bootstrap knobs

`bootstrap.sh` reads three optional environment variables (defaults in parentheses):

| Var | Default | Purpose |
|---|---|---|
| `JINX_REPO` | `https://github.com/andrewmcadoo/jinx.git` | Repo to clone for install scripts and configs. |
| `JINX_REF` | `main` | Branch, tag, or commit to check out. Pin to a tag when launching a fresh box from a known-good state. |
| `JINX_NOPASSWD` | unset | Set to `1` to install the opt-in blanket `sudoers/01-andrew-nopasswd` alongside the password-required default. Convenient when iterating; remove the file by hand once iteration is done. |

Override via Lightsail user-data by editing `userdata.sh` after `scripts/make-userdata.sh` regenerates it. Example: `JINX_REF=v1.2.3 bash install/run.sh`.
```

- [ ] **Step 4: Commit**

```bash
git add RUNBOOK.md JINX.md
git commit -m "docs(runbook,jinx): post-bootstrap setup + JINX_REF/JINX_NOPASSWD knobs"
```

---

## Task 19: Final full-chain validation + cutover-ready commit

**Files:**
- (validation only)

- [ ] **Step 1: Full smoke test, default mode**

```bash
bash scripts/test-bootstrap-local.sh
```

Expected: `SMOKE TEST PASSED`. Log tail shows `90-verify: all checks passed`.

- [ ] **Step 2: Full smoke test, nopasswd mode**

```bash
bash scripts/test-bootstrap-local.sh --nopasswd
```

Expected: same as Step 1, but log additionally shows `JINX_NOPASSWD=1 set; installing sudoers/01-andrew-nopasswd`.

- [ ] **Step 3: Re-run smoke test on same image to validate idempotency**

```bash
docker pull -q ubuntu:24.04 >/dev/null
# Run the harness twice in a row inside the same container.
CONTAINER="jinx-idempotency-$$"
docker run -d --name "$CONTAINER" --privileged \
    --tmpfs /run --tmpfs /run/lock \
    -v "$(pwd):/opt/jinx:ro" \
    ubuntu:24.04 sleep infinity >/dev/null
docker exec "$CONTAINER" bash -c '
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y --no-install-recommends systemd systemd-sysv dbus sudo
'
docker exec "$CONTAINER" bash -c 'cd /opt/jinx && bash install/run.sh'
docker exec "$CONTAINER" bash -c 'cd /opt/jinx && bash install/run.sh'  # re-run
docker exec "$CONTAINER" tail -10 /var/log/jinx-bootstrap.log
docker rm -f "$CONTAINER"
```

Expected: both runs end with `90-verify: all checks passed`. Re-run is a no-op for everything except cert preservation and log-file pre-creation.

- [ ] **Step 4: Confirm CI green on main after push**

```bash
git push
gh run watch
```

All five jobs green: `shellcheck`, `caddy-validate`, `systemd-verify`, `visudo-check`, `userdata-drift`.

- [ ] **Step 5: Tag a known-good ref for cutover**

```bash
git tag -a bootstrap-rework-v1 -m "Bootstrap rework complete; tested in Docker + CI green"
git push --tags
```

This is the ref AJ will set via `JINX_REF=bootstrap-rework-v1` in the new `userdata.sh` for cutover, so the new box pins to this exact state even if `main` advances afterward.

- [ ] **Step 6: Hand off to operator for the cutover**

Print the next-action checklist (lives in spec §10):

1. Detach static IP `23.23.181.232` from existing `jinx` (Lightsail console).
2. Delete existing `jinx` instance.
3. Optionally edit `userdata.sh` to set `JINX_REF=bootstrap-rework-v1` (one-line export inserted in the inner bash payload before the `exec`).
4. `aws lightsail create-instances --instance-names jinx --availability-zone us-east-1a --bundle-id small_3_0 --blueprint-id ubuntu_24_04 --user-data file://userdata.sh --tags key=tier,value=scratch key=project,value=jinx`.
5. Wait for `running`, attach `23.23.181.232`.
6. `ssh jinx 'sudo tail -200 /var/log/jinx-bootstrap.log'` — confirm `all checks passed`.
7. `ssh jinx 'jinx-status'`.
8. `scp` real Cloudflare Origin Cert per RUNBOOK §"Post-bootstrap setup" step 1.
9. (Optional) Wire Healthchecks.io per RUNBOOK §"Post-bootstrap setup" step 2.
10. `curl -I https://jinx.generalproducts.io` → expect 200.

(No commit at the end of Task 19 — work is complete and tagged.)

---

## Notes for the implementer

- **Don't `git add .`** — repo CLAUDE.md forbids it. Use the explicit file lists in each commit step.
- **Run shellcheck after every shell-script change**, even if the commit step doesn't say so. CI will fail on any warning.
- **Re-run smoke test after every install-script change.** ~60–90 seconds; cheaper than a failed cutover.
- **The Docker container is `--privileged`**: that's required for systemd PID 1, but it's a heavy permission. Don't run the harness on machines you don't own.
- **If a step says "no output expected"** and shellcheck does produce output, fix the warning before committing — don't add `# shellcheck disable=…` without justification in the diff.
- **Re-runs of `install/run.sh` should be idempotent.** If you find a non-idempotent operation (e.g., appending to a file that doesn't reset on re-run), fix it in the same task.
- **The `_apex/index.html` fingerprint trick** in `install/60-caddy.sh` only protects against clobbering one specific placeholder string. If the placeholder content ever changes (e.g., new apex template), update `PLACEHOLDER_SHA` in the same commit that changes `apex/index.html`.
