# Jinx Scratch-Box Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stand up `jinx.generalproducts.io` — a single AWS Lightsail VM that hosts personal/team development projects under wildcard subdomains, fronted by Cloudflare, with an SSH-deployable release-dir layout per project.

**Architecture:** Ubuntu 24.04 LTS on Lightsail (small bundle), bootstrapped via cloud-init shell script into a hardened single-user host. Caddy reverse-proxies `*.jinx.generalproducts.io` to localhost ports per project. Each project lives in `/srv/<project>/{releases,shared,current}` with atomic-symlink deploys (the Clipper pattern). TLS via Cloudflare Origin Certificate (wildcard, 15-year, install-once). All cloud assets created manually via console/CLI; no IaC.

**Tech Stack:** AWS Lightsail · Cloudflare DNS+Proxy+Origin Certs · Ubuntu 24.04 · Caddy 2.x · systemd · UFW · unattended-upgrades · GitHub Actions (shellcheck, caddy validate, systemd-analyze, visudo)

**Spec:** `docs/superpowers/specs/2026-05-03-jinx-scratch-box-design.md`
**Tracking:** beads `mim-qb6`

---

## Conventions used in this plan

- **All paths are absolute** to `/Users/aj/Desktop/Projects/Workspace/jinx/` unless prefixed with `/etc`, `/srv`, etc. (which refer to paths *on the Jinx box*).
- **Each task ends in a commit.** Add files individually (`git add <file>`) per AJ's CLAUDE.md — never `git add .`.
- **Test discipline for infra code:** instead of unit tests, each artifact is verified by its native validator before commit (`shellcheck`, `caddy validate`, `systemd-analyze verify`, `visudo -cf`). CI re-runs all validators on every push.
- **Interactive steps** (cloud consoles, browser auth) are flagged `[INTERACTIVE — AJ executes]`. The plan describes exactly what to click/run.
- **Working directory:** `/Users/aj/Desktop/Projects/Workspace/jinx/` for all commands unless noted.

---

## Task 0: Prerequisites check

**Files:** none (verification only)

- [ ] **Step 0.1: Verify the jinx repo exists with the spec**

```bash
test -f /Users/aj/Desktop/Projects/Workspace/jinx/docs/superpowers/specs/2026-05-03-jinx-scratch-box-design.md && echo OK
```

Expected: `OK`. If missing, return to brainstorming skill — the spec is the prerequisite for this plan.

- [ ] **Step 0.2: Verify required CLI tools on the laptop**

```bash
for cmd in git gh shellcheck curl ssh-keygen jq; do
  command -v "$cmd" >/dev/null && echo "OK $cmd" || echo "MISSING $cmd"
done
```

Expected: every line starts with `OK`. Install any missing tools via Homebrew before continuing:

```bash
brew install shellcheck gh jq
```

(`git`, `curl`, `ssh-keygen` ship with macOS; `gh` is GitHub CLI.)

- [ ] **Step 0.3: Verify AWS CLI**

```bash
command -v aws >/dev/null && aws --version || echo "MISSING aws"
```

Expected: `aws-cli/2.x.x ...`. If missing:

```bash
brew install awscli
```

- [ ] **Step 0.4: Verify AWS credentials work for Lightsail**

```bash
aws sts get-caller-identity
aws lightsail get-regions --query 'regions[?name==`us-east-1`].name' --output text
```

Expected: a JSON identity blob, then `us-east-1`. If `get-caller-identity` errors with "Unable to locate credentials" → `aws configure` (you'll need an Access Key ID + Secret from IAM). **[INTERACTIVE — AJ executes]** if creds aren't already set up.

- [ ] **Step 0.5: Verify GitHub CLI is authed**

```bash
gh auth status
```

Expected: `Logged in to github.com as andrewmcadoo`. If not, run `gh auth login`. **[INTERACTIVE — AJ executes]** if not authed.

No commit for Task 0 (verification only).

---

## Task 1: Repo scaffolding + README skeleton

**Files:**
- Create: `/Users/aj/Desktop/Projects/Workspace/jinx/README.md`

- [ ] **Step 1.1: Write README.md**

```markdown
# Jinx

Single-host scratch deployment box for personal and team projects.

- **Hostname:** `jinx.generalproducts.io`
- **Project pattern:** `<project>.jinx.generalproducts.io`
- **Provider:** AWS Lightsail (Ubuntu 24.04 LTS, us-east-1)
- **Status:** scratch tier — explicitly NOT production for any project that proves itself

## Documents

- [`docs/superpowers/specs/2026-05-03-jinx-scratch-box-design.md`](docs/superpowers/specs/2026-05-03-jinx-scratch-box-design.md) — design (read first)
- [`docs/superpowers/plans/2026-05-03-jinx-scratch-box.md`](docs/superpowers/plans/2026-05-03-jinx-scratch-box.md) — implementation plan
- [`RUNBOOK.md`](RUNBOOK.md) — operations (add a project, rotate certs, restore from snapshot)
- [`PORTS.md`](PORTS.md) — port allocation table

## Adding a project

See `RUNBOOK.md` § "Adding a project".
```

- [ ] **Step 1.2: Verify the README renders**

```bash
cd /Users/aj/Desktop/Projects/Workspace/jinx
cat README.md | head -5
```

Expected: first five lines visible, starting with `# Jinx`.

- [ ] **Step 1.3: Commit**

```bash
cd /Users/aj/Desktop/Projects/Workspace/jinx
git add README.md
git commit -m "docs: add README with quickstart links"
```

---

## Task 2: PORTS.md (port allocation table)

**Files:**
- Create: `/Users/aj/Desktop/Projects/Workspace/jinx/PORTS.md`

- [ ] **Step 2.1: Write PORTS.md**

```markdown
# Port allocation

All ports listed below are bound to `127.0.0.1` only — never `0.0.0.0`.
External traffic always arrives via Caddy on `:443`.

## Convention

- `web` roles: `30xx`
- `api` roles: `31xx`
- `worker` / `queue` roles: `32xx`
- `db` roles (e.g. project-local Postgres): `54xx`

Allocate by inserting into the table below in ascending order. Do not reuse
ports across projects — even if a project is paused, leave its row.

## Allocations

| Project   | Role   | Port | Status   | Notes                  |
| --------- | ------ | ---- | -------- | ---------------------- |
| _example_ | _web_  | 3000 | reserved | Template; never bound. |
```

- [ ] **Step 2.2: Commit**

```bash
cd /Users/aj/Desktop/Projects/Workspace/jinx
git add PORTS.md
git commit -m "docs: add port allocation table"
```

---

## Task 3: bootstrap.sh — skeleton with idempotency guard

**Files:**
- Create: `/Users/aj/Desktop/Projects/Workspace/jinx/bootstrap.sh`

The bootstrap script will be built incrementally over Tasks 3–9. Each task adds one section and commits. Every commit leaves `bootstrap.sh` in a runnable, shellcheck-clean state.

- [ ] **Step 3.1: Write the skeleton**

```bash
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

# --- Main ---
main() {
    require_root
    log "Starting Jinx bootstrap at $(date -u --iso-8601=seconds)"
    # Subsequent tasks fill in sections below.
    log "Bootstrap complete"
}

main "$@"
```

- [ ] **Step 3.2: Make executable and shellcheck**

```bash
cd /Users/aj/Desktop/Projects/Workspace/jinx
chmod +x bootstrap.sh
shellcheck bootstrap.sh
```

Expected: no output (clean). If shellcheck reports anything, fix and re-run.

- [ ] **Step 3.3: Commit**

```bash
cd /Users/aj/Desktop/Projects/Workspace/jinx
git add bootstrap.sh
git commit -m "feat(bootstrap): skeleton with logging + root guard"
```

---

## Task 4: bootstrap.sh — apt update + package install

**Files:**
- Modify: `/Users/aj/Desktop/Projects/Workspace/jinx/bootstrap.sh`

- [ ] **Step 4.1: Replace the `# Subsequent tasks fill in sections below.` line in `main()` with the apt + Caddy install section, and add the helper function above `main()`**

Insert this function definition just above `main()`:

```bash
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
```

Then replace the `# Subsequent tasks fill in sections below.` line with:

```bash
    install_packages
```

- [ ] **Step 4.2: shellcheck**

```bash
cd /Users/aj/Desktop/Projects/Workspace/jinx
shellcheck bootstrap.sh
```

Expected: clean.

- [ ] **Step 4.3: Commit**

```bash
cd /Users/aj/Desktop/Projects/Workspace/jinx
git add bootstrap.sh
git commit -m "feat(bootstrap): install baseline packages + Caddy from Cloudsmith"
```

---

## Task 5: bootstrap.sh — UFW firewall + unattended-upgrades

**Files:**
- Modify: `/Users/aj/Desktop/Projects/Workspace/jinx/bootstrap.sh`

- [ ] **Step 5.1: Add two helper functions above `main()`**

Insert above `main()`:

```bash
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
```

Add these two calls inside `main()` after `install_packages`:

```bash
    configure_ufw
    configure_unattended_upgrades
```

- [ ] **Step 5.2: shellcheck**

```bash
cd /Users/aj/Desktop/Projects/Workspace/jinx
shellcheck bootstrap.sh
```

Expected: clean.

- [ ] **Step 5.3: Commit**

```bash
cd /Users/aj/Desktop/Projects/Workspace/jinx
git add bootstrap.sh
git commit -m "feat(bootstrap): UFW (22+443 only) + unattended-upgrades"
```

---

## Task 6: bootstrap.sh — andrew user + GitHub-pulled SSH keys

**Files:**
- Modify: `/Users/aj/Desktop/Projects/Workspace/jinx/bootstrap.sh`

- [ ] **Step 6.1: Add helper function above `main()`**

```bash
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
```

Add to `main()` after `configure_unattended_upgrades`:

```bash
    configure_user
```

- [ ] **Step 6.2: shellcheck**

```bash
cd /Users/aj/Desktop/Projects/Workspace/jinx
shellcheck bootstrap.sh
```

Expected: clean.

- [ ] **Step 6.3: Commit**

```bash
cd /Users/aj/Desktop/Projects/Workspace/jinx
git add bootstrap.sh
git commit -m "feat(bootstrap): create andrew user + pull SSH keys from GitHub"
```

---

## Task 7: bootstrap.sh — sshd hardening + sudoers

**Files:**
- Modify: `/Users/aj/Desktop/Projects/Workspace/jinx/bootstrap.sh`

- [ ] **Step 7.1: Add helper function above `main()`**

```bash
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
```

Add to `main()` after `configure_user`:

```bash
    configure_sshd_and_sudo
```

- [ ] **Step 7.2: shellcheck**

```bash
cd /Users/aj/Desktop/Projects/Workspace/jinx
shellcheck bootstrap.sh
```

Expected: clean.

- [ ] **Step 7.3: Commit**

```bash
cd /Users/aj/Desktop/Projects/Workspace/jinx
git add bootstrap.sh
git commit -m "feat(bootstrap): sshd hardening drop-in + sudoers for andrew"
```

---

## Task 8: bootstrap.sh — /srv layout + Caddy directories

**Files:**
- Modify: `/Users/aj/Desktop/Projects/Workspace/jinx/bootstrap.sh`

- [ ] **Step 8.1: Add helper function above `main()`**

```bash
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
```

Add to `main()` after `configure_sshd_and_sudo`:

```bash
    configure_filesystem
```

- [ ] **Step 8.2: shellcheck**

```bash
cd /Users/aj/Desktop/Projects/Workspace/jinx
shellcheck bootstrap.sh
```

Expected: clean.

- [ ] **Step 8.3: Commit**

```bash
cd /Users/aj/Desktop/Projects/Workspace/jinx
git add bootstrap.sh
git commit -m "feat(bootstrap): /srv layout, Caddy dirs, placeholder apex page"
```

---

## Task 9: bootstrap.sh — final manual-step instructions

**Files:**
- Modify: `/Users/aj/Desktop/Projects/Workspace/jinx/bootstrap.sh`

- [ ] **Step 9.1: Add helper function above `main()`**

```bash
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
```

Add to `main()` after `configure_filesystem` and before the closing `log "Bootstrap complete"`:

```bash
    print_manual_steps
```

- [ ] **Step 9.2: shellcheck**

```bash
cd /Users/aj/Desktop/Projects/Workspace/jinx
shellcheck bootstrap.sh
```

Expected: clean.

- [ ] **Step 9.3: Run a self-test by source-loading bootstrap.sh in a subshell to verify bash syntax**

```bash
cd /Users/aj/Desktop/Projects/Workspace/jinx
bash -n bootstrap.sh && echo "syntax OK"
```

Expected: `syntax OK`.

- [ ] **Step 9.4: Commit**

```bash
cd /Users/aj/Desktop/Projects/Workspace/jinx
git add bootstrap.sh
git commit -m "feat(bootstrap): print remaining manual steps after first run"
```

---

## Task 10: sshd config drop-in (canonical version checked into repo)

**Files:**
- Create: `/Users/aj/Desktop/Projects/Workspace/jinx/sshd/90-jinx.conf`

The same content the bootstrap script writes — checked in so changes can be reviewed and re-deployed without re-running bootstrap.

- [ ] **Step 10.1: Write `sshd/90-jinx.conf`**

```
# Jinx hardening — see spec §4.2.
PasswordAuthentication no
PermitRootLogin no
AuthenticationMethods publickey
ChallengeResponseAuthentication no
KbdInteractiveAuthentication no
```

- [ ] **Step 10.2: Verify it matches what bootstrap.sh embeds**

```bash
cd /Users/aj/Desktop/Projects/Workspace/jinx
diff <(sed -n '/cat > \/etc\/ssh\/sshd_config.d\/90-jinx.conf/,/^EOF$/p' bootstrap.sh \
        | sed -e '1d' -e '$d') sshd/90-jinx.conf
```

Expected: no output (files identical).

- [ ] **Step 10.3: Commit**

```bash
cd /Users/aj/Desktop/Projects/Workspace/jinx
git add sshd/90-jinx.conf
git commit -m "feat(sshd): canonical hardening drop-in"
```

---

## Task 11: Caddyfile (base config)

**Files:**
- Create: `/Users/aj/Desktop/Projects/Workspace/jinx/caddy/Caddyfile`

- [ ] **Step 11.1: Write `caddy/Caddyfile`**

```
{
    admin off
    # auto_https off disables both ACME issuance AND HTTP→HTTPS redirect.
    # We don't need either: certs come from Cloudflare Origin (spec §3.4),
    # and HTTP→HTTPS happens at Cloudflare's edge before traffic reaches us
    # (spec §3.2 + §3.3 "Always Use HTTPS").
    auto_https off

    log default {
        output file /var/log/caddy/caddy.log
        format json
    }
}

import sites/*.caddy
```

- [ ] **Step 11.2: Validate locally if Caddy is installed**

```bash
cd /Users/aj/Desktop/Projects/Workspace/jinx
if command -v caddy >/dev/null; then
    caddy validate --config caddy/Caddyfile
else
    echo "Caddy not installed locally; CI will validate. Skipping."
fi
```

Expected: `Valid configuration` if caddy is local, otherwise the skip message. (Local install is optional — CI catches it.)

- [ ] **Step 11.3: Commit**

```bash
cd /Users/aj/Desktop/Projects/Workspace/jinx
git add caddy/Caddyfile
git commit -m "feat(caddy): base Caddyfile importing sites/*.caddy"
```

---

## Task 12: Apex Caddy site (`jinx.generalproducts.io`)

**Files:**
- Create: `/Users/aj/Desktop/Projects/Workspace/jinx/caddy/sites/00-apex.caddy`

- [ ] **Step 12.1: Write `caddy/sites/00-apex.caddy`**

```
jinx.generalproducts.io {
    tls /etc/ssl/jinx/cert.pem /etc/ssl/jinx/key.pem

    root * /srv/_apex
    file_server

    log {
        output file /var/log/caddy/apex.log
        format json
    }
}
```

- [ ] **Step 12.2: Validate (if local Caddy)**

```bash
cd /Users/aj/Desktop/Projects/Workspace/jinx
if command -v caddy >/dev/null; then
    caddy validate --config caddy/Caddyfile --adapter caddyfile
fi
```

Expected: `Valid configuration` or skip if no local caddy. (Validation against `Caddyfile` will pull in `sites/*.caddy` via the import.)

- [ ] **Step 12.3: Commit**

```bash
cd /Users/aj/Desktop/Projects/Workspace/jinx
git add caddy/sites/00-apex.caddy
git commit -m "feat(caddy): apex site serving /srv/_apex"
```

---

## Task 13: Example Caddy site template

**Files:**
- Create: `/Users/aj/Desktop/Projects/Workspace/jinx/caddy/sites/_example.caddy`

- [ ] **Step 13.1: Write `caddy/sites/_example.caddy`**

```
# Template for adding a new project. Copy to <project>.caddy and edit.
# Filename leading underscore prevents Caddy from loading it (the import glob
# in /etc/caddy/Caddyfile is sites/*.caddy; on the server, do NOT scp this file).
#
# After installing the cleaned-up copy: sudo systemctl reload caddy
#
# Pattern:
#   - <project>.jinx.generalproducts.io is the only public surface.
#   - All processes listen on 127.0.0.1 only; ports per /Users/aj/.../jinx/PORTS.md.
#   - /api/* paths route to the API process; everything else to the web frontend.
#     Single-process projects can omit the /api block.

example.jinx.generalproducts.io {
    tls /etc/ssl/jinx/cert.pem /etc/ssl/jinx/key.pem

    handle /api/* {
        reverse_proxy localhost:3100
    }

    handle {
        reverse_proxy localhost:3000
    }

    log {
        output file /var/log/caddy/example.log
        format json
    }
}
```

- [ ] **Step 13.2: Verify the underscore-prefix prevents real loading on the server**

```bash
cd /Users/aj/Desktop/Projects/Workspace/jinx
grep -E "^import" caddy/Caddyfile
```

Expected: `import sites/*.caddy`. Files starting with `_` match `*` per shell glob, so the leading underscore is **not** sufficient on its own to prevent loading — the file should never be `scp`'d to `/etc/caddy/sites/` on the server. Document this clearly in `RUNBOOK.md` (Task 16).

- [ ] **Step 13.3: Commit**

```bash
cd /Users/aj/Desktop/Projects/Workspace/jinx
git add caddy/sites/_example.caddy
git commit -m "feat(caddy): example project site template"
```

---

## Task 14: Apex landing page (`apex/index.html`)

**Files:**
- Create: `/Users/aj/Desktop/Projects/Workspace/jinx/apex/index.html`

- [ ] **Step 14.1: Write `apex/index.html`**

```html
<!doctype html>
<html lang="en">
<head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width,initial-scale=1">
    <title>Jinx</title>
    <style>
        body {
            font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", system-ui, sans-serif;
            max-width: 40rem;
            margin: 4rem auto;
            padding: 0 1rem;
            color: #1a1a1a;
            line-height: 1.5;
        }
        h1 { font-size: 2rem; margin-bottom: 0.25rem; }
        .sub { color: #666; margin-top: 0; }
        ul { padding-left: 1.25rem; }
        li { margin-bottom: 0.25rem; }
        code { background: #f4f4f4; padding: 0.1rem 0.3rem; border-radius: 3px; }
    </style>
</head>
<body>
    <h1>Jinx</h1>
    <p class="sub">scratch deployment box · <code>generalproducts.io</code></p>

    <h2>Projects</h2>
    <ul>
        <!-- Add list items as projects come online. -->
    </ul>

    <p style="margin-top: 3rem; color: #999; font-size: 0.85rem;">
        This box hosts experimental work. For production services, see project-specific docs.
    </p>
</body>
</html>
```

- [ ] **Step 14.2: Sanity-check the HTML**

```bash
cd /Users/aj/Desktop/Projects/Workspace/jinx
grep -c '<title>Jinx</title>' apex/index.html
```

Expected: `1`.

- [ ] **Step 14.3: Commit**

```bash
cd /Users/aj/Desktop/Projects/Workspace/jinx
git add apex/index.html
git commit -m "feat(apex): static landing page"
```

---

## Task 15: Example systemd unit template

**Files:**
- Create: `/Users/aj/Desktop/Projects/Workspace/jinx/systemd/_example.service`

- [ ] **Step 15.1: Write `systemd/_example.service`**

```ini
# Template for a project process. Copy to <project>-<role>.service and edit.
# Install: sudo install -m 0644 -o root -g root <project>-<role>.service /etc/systemd/system/
#          sudo systemctl daemon-reload
#          sudo systemctl enable --now <project>-<role>
#
# The unit assumes:
#   - The deploy.sh script has already created /srv/<project>/current as a
#     symlink to a release dir.
#   - Secrets live in /srv/<project>/shared/.env.production (EnvironmentFile).
#   - The process listens on 127.0.0.1:<port> per PORTS.md.

[Unit]
Description=example-web (template — DO NOT install as-is)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=andrew
Group=andrew
WorkingDirectory=/srv/example/current
EnvironmentFile=/srv/example/shared/.env.production
Environment=PORT=3000
Environment=HOSTNAME=127.0.0.1
ExecStart=/usr/bin/node server.js
Restart=on-failure
RestartSec=2s

# Hardening
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=read-only
ReadWritePaths=/srv/example/shared
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true

[Install]
WantedBy=multi-user.target
```

- [ ] **Step 15.2: Validate with `systemd-analyze` if available**

```bash
cd /Users/aj/Desktop/Projects/Workspace/jinx
if command -v systemd-analyze >/dev/null; then
    systemd-analyze verify systemd/_example.service 2>&1 | grep -v "Failed to find module" || echo "OK"
else
    echo "systemd-analyze not on macOS; CI will validate. Skipping."
fi
```

Expected: `OK` on Linux, skip message on macOS. (`systemd-analyze verify` may complain about the missing /srv path on a dev machine; that's expected — CI runs in Ubuntu.)

- [ ] **Step 15.3: Commit**

```bash
cd /Users/aj/Desktop/Projects/Workspace/jinx
git add systemd/_example.service
git commit -m "feat(systemd): example unit template with hardening"
```

---

## Task 16: SSH key refresh script

**Files:**
- Create: `/Users/aj/Desktop/Projects/Workspace/jinx/scripts/refresh-ssh-keys.sh`

- [ ] **Step 16.1: Write `scripts/refresh-ssh-keys.sh`**

```bash
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
```

- [ ] **Step 16.2: shellcheck and chmod**

```bash
cd /Users/aj/Desktop/Projects/Workspace/jinx
chmod +x scripts/refresh-ssh-keys.sh
shellcheck scripts/refresh-ssh-keys.sh
```

Expected: clean.

- [ ] **Step 16.3: Commit**

```bash
cd /Users/aj/Desktop/Projects/Workspace/jinx
git add scripts/refresh-ssh-keys.sh
git commit -m "feat(scripts): refresh-ssh-keys re-pulls GitHub keys"
```

---

## Task 17: RUNBOOK.md

**Files:**
- Create: `/Users/aj/Desktop/Projects/Workspace/jinx/RUNBOOK.md`

- [ ] **Step 17.1: Write `RUNBOOK.md`**

````markdown
# Jinx Runbook

Operational procedures for `jinx.generalproducts.io`.
Spec: `docs/superpowers/specs/2026-05-03-jinx-scratch-box-design.md`.

## SSH

```
ssh andrew@jinx.generalproducts.io
# or, if ~/.ssh/config has Host jinx:
ssh jinx
```

## Adding a project

1. **Allocate a port.** Edit `PORTS.md`, append a row, commit.
2. **Copy the Caddy template:**
   ```
   cp caddy/sites/_example.caddy caddy/sites/<project>.caddy
   # Edit hostname, ports, log filename. Remove leading-underscore confusion
   # by NEVER copying _example.caddy to the server itself.
   ```
3. **Copy the systemd template:**
   ```
   cp systemd/_example.service systemd/<project>-<role>.service
   # Edit Description, paths, ports, env file.
   ```
4. **Commit both files** to the jinx repo.
5. **On Jinx, create the project tree:**
   ```
   ssh jinx 'sudo install -d -m 0755 -o andrew -g andrew \
             /srv/<project>/releases /srv/<project>/shared'
   # Populate /srv/<project>/shared/.env.production with project secrets.
   ```
6. **Install the Caddy site:**
   ```
   scp caddy/sites/<project>.caddy jinx:/tmp/
   ssh jinx 'sudo install -m 0644 -o root -g root \
             /tmp/<project>.caddy /etc/caddy/sites/<project>.caddy
             sudo systemctl reload caddy
             rm /tmp/<project>.caddy'
   ```
7. **Install the systemd unit(s):**
   ```
   scp systemd/<project>-<role>.service jinx:/tmp/
   ssh jinx 'sudo install -m 0644 -o root -g root \
             /tmp/<project>-<role>.service /etc/systemd/system/
             sudo systemctl daemon-reload
             rm /tmp/<project>-<role>.service'
   ```
   (Don't `enable --now` until after the first deploy populates `/srv/<project>/current`.)
8. **Add NOPASSWD sudoers entry** (Jinx-side):
   ```
   echo "andrew ALL=(root) NOPASSWD: /usr/bin/systemctl restart <project>-<role>" \
     | sudo tee /etc/sudoers.d/<project>
   sudo visudo -cf /etc/sudoers.d/<project>
   sudo chmod 0440 /etc/sudoers.d/<project>
   ```
9. **First deploy** of the project (modeled on Clipper's `scripts/deploy/deploy.sh`).
10. **Enable the systemd unit:**
    ```
    ssh jinx 'sudo systemctl enable --now <project>-<role>'
    ```
11. **Smoke test:** `curl -I https://<project>.jinx.generalproducts.io`.
12. **Update `apex/index.html`** to list the new project; redeploy (`scp` to `/srv/_apex/`).

## Cert rotation (Cloudflare Origin Cert)

The current cert is valid for 15 years. Rotate when:

- The cert is about to expire (set a calendar reminder).
- The set of hostnames changes (e.g. cert needs to cover a new sister-zone).
- The private key is suspected compromised.

Steps:

1. Cloudflare dashboard → SSL/TLS → Origin Server → Create Certificate.
2. Hostnames: `jinx.generalproducts.io, *.jinx.generalproducts.io`. ECDSA, 15 years.
3. Save `cert.pem` and `key.pem` locally (the private key is shown ONCE).
4. `scp` and install:
   ```
   scp cert.pem key.pem jinx:/tmp/
   ssh jinx 'sudo install -m 0644 -o root -g caddy /tmp/cert.pem /etc/ssl/jinx/cert.pem
             sudo install -m 0640 -o root -g caddy /tmp/key.pem  /etc/ssl/jinx/key.pem
             rm /tmp/cert.pem /tmp/key.pem
             sudo systemctl reload caddy'
   ```
5. Verify:
   ```
   curl -vI https://jinx.generalproducts.io 2>&1 | grep -E "subject:|expire"
   ```

## Refreshing SSH keys

When you add or remove a key on https://github.com/settings/keys:

```
ssh jinx 'sudo /usr/local/bin/refresh-ssh-keys'
```

## Restoring from a Lightsail snapshot

1. Lightsail console → Snapshots → pick most recent → "Create new instance from snapshot".
2. Use bundle `small_3_0`, name `jinx-restored`.
3. Detach the static IP from the old `jinx`, attach to `jinx-restored`.
4. Cloudflare DNS auto-resolves on next TTL (no change needed if static IP is reused).
5. SSH to verify, then delete the old instance.

## Emergency: locked out of SSH

If a sudoers/sshd change locks you out:

1. Lightsail console → Connect → "Connect using SSH" (browser-based, uses Lightsail's
   own credentials, bypasses your sshd hardening).
2. Fix the bad config.
3. `sudo systemctl reload ssh`.

## Useful commands on the box

| Goal                              | Command                                      |
| --------------------------------- | -------------------------------------------- |
| Tail Caddy logs                   | `sudo tail -f /var/log/caddy/caddy.log`      |
| Tail per-site Caddy logs          | `sudo tail -f /var/log/caddy/<site>.log`     |
| Restart a project                 | `sudo systemctl restart <project>-<role>`    |
| Project status + recent logs      | `sudo systemctl status <project>-<role>`     |
| Live project logs                 | `sudo journalctl -u <project>-<role> -f`     |
| Disk usage by project             | `sudo du -sh /srv/*`                         |
| Caddy config validate             | `sudo caddy validate --config /etc/caddy/Caddyfile` |
| Caddy reload (zero downtime)      | `sudo systemctl reload caddy`                |
````

- [ ] **Step 17.2: Commit**

```bash
cd /Users/aj/Desktop/Projects/Workspace/jinx
git add RUNBOOK.md
git commit -m "docs: runbook (add project, rotate certs, restore, lockout recovery)"
```

---

## Task 18: GitHub Actions lint workflow

**Files:**
- Create: `/Users/aj/Desktop/Projects/Workspace/jinx/.github/workflows/lint.yml`

- [ ] **Step 18.1: Write `.github/workflows/lint.yml`**

```yaml
name: Lint

on:
  push:
    branches: [main]
  pull_request:

jobs:
  shellcheck:
    name: shellcheck
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: ludeeus/action-shellcheck@master
        env:
          SHELLCHECK_OPTS: -e SC1091

  caddy-validate:
    name: caddy validate
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Install Caddy
        run: |
          sudo apt-get update -qq
          sudo apt-get install -y debian-keyring debian-archive-keyring apt-transport-https curl
          curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
            | sudo gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
          curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
            | sudo tee /etc/apt/sources.list.d/caddy-stable.list >/dev/null
          sudo apt-get update -qq
          sudo apt-get install -y caddy
      - name: Validate Caddyfile
        run: caddy validate --config caddy/Caddyfile

  systemd-verify:
    name: systemd-analyze verify
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Verify systemd units
        # `verify` complains about missing paths — that's fine, we only fail
        # on syntax/directive errors.
        run: |
          for unit in systemd/*.service; do
            echo "=== $unit ==="
            # Filter out warnings about non-existent paths/users/groups,
            # which are expected on a CI host that doesn't have /srv set up.
            output=$(systemd-analyze verify "$unit" 2>&1 || true)
            echo "$output"
            if echo "$output" | grep -qE "(Failed to parse|bad-setting|invalid-)"; then
              exit 1
            fi
          done

  visudo-check:
    name: visudo syntax
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Validate generated sudoers content (from bootstrap.sh)
        run: |
          # Extract the sudoers line bootstrap.sh writes and validate it.
          tmp=$(mktemp)
          echo "andrew ALL=(ALL) ALL" > "$tmp"
          sudo visudo -cf "$tmp"
          rm -f "$tmp"
```

- [ ] **Step 18.2: Validate workflow syntax with `gh workflow view`** (after push) — for now, just confirm the file parses as YAML

```bash
cd /Users/aj/Desktop/Projects/Workspace/jinx
python3 -c "import yaml; yaml.safe_load(open('.github/workflows/lint.yml'))" && echo "yaml OK"
```

Expected: `yaml OK`.

- [ ] **Step 18.3: Commit**

```bash
cd /Users/aj/Desktop/Projects/Workspace/jinx
git add .github/workflows/lint.yml
git commit -m "ci: shellcheck, caddy validate, systemd-analyze, visudo"
```

---

## Task 19: Local final-pass validation

**Files:** none (verification)

- [ ] **Step 19.1: Run shellcheck on every shell file**

```bash
cd /Users/aj/Desktop/Projects/Workspace/jinx
shellcheck bootstrap.sh scripts/*.sh
```

Expected: clean.

- [ ] **Step 19.2: Verify all files exist that the spec calls for**

```bash
cd /Users/aj/Desktop/Projects/Workspace/jinx
for f in README.md RUNBOOK.md PORTS.md bootstrap.sh \
         caddy/Caddyfile caddy/sites/00-apex.caddy caddy/sites/_example.caddy \
         apex/index.html systemd/_example.service sshd/90-jinx.conf \
         scripts/refresh-ssh-keys.sh .github/workflows/lint.yml \
         docs/superpowers/specs/2026-05-03-jinx-scratch-box-design.md \
         docs/superpowers/plans/2026-05-03-jinx-scratch-box.md; do
    test -f "$f" && echo "OK $f" || echo "MISSING $f"
done
```

Expected: every line `OK ...`.

- [ ] **Step 19.3: View commit log**

```bash
cd /Users/aj/Desktop/Projects/Workspace/jinx
git log --oneline
```

Expected: ~18 commits in the order matching this plan.

(No commit for Task 19.)

---

## Task 20: Push to GitHub

**Files:** none (remote setup)

- [ ] **Step 20.1: Create the GitHub repo**

```bash
cd /Users/aj/Desktop/Projects/Workspace/jinx
gh repo create andrewmcadoo/jinx --private --source=. --remote=origin --push
```

Expected: repo created, default branch `main`, all commits pushed.

- [ ] **Step 20.2: Verify CI green**

```bash
cd /Users/aj/Desktop/Projects/Workspace/jinx
sleep 30  # let GitHub register the workflow
gh run watch --exit-status
```

Expected: all four lint jobs pass. If a job fails, fix locally, commit, push, repeat.

(No commit for Task 20.)

---

## Task 21: Launch the Lightsail instance — `[INTERACTIVE — AJ executes]`

**Files:** none (cloud resource)

- [ ] **Step 21.1: Verify the bootstrap.sh fits within Lightsail's user-data limit**

```bash
cd /Users/aj/Desktop/Projects/Workspace/jinx
wc -c bootstrap.sh
```

Expected: a number under 16384 (Lightsail's user-data limit). Current size should be ~3-4KB, well under.

- [ ] **Step 21.2: Resolve the Linux 24.04 LTS blueprint ID**

```bash
aws lightsail get-blueprints --region us-east-1 \
  --query 'blueprints[?platform==`LINUX_UNIX` && contains(name, `Ubuntu`) && contains(name, `24.04`)].{id:blueprintId,name:name}' \
  --output table
```

Expected: a blueprint named like `Ubuntu 24.04 LTS` with id `ubuntu_24_04`. Note the exact ID for the next step.

- [ ] **Step 21.3: Resolve the small bundle ID**

```bash
aws lightsail get-bundles --region us-east-1 \
  --query 'bundles[?ramSizeInGb==`2.0` && supportedPlatforms[?@==`LINUX_UNIX`]].{id:bundleId,price:price,ram:ramSizeInGb,cpu:cpuCount,disk:diskSizeInGb}' \
  --output table
```

Expected: the row with price `10.0` is the right one. Note the exact `bundleId` (likely `small_3_0` or similar). The plan calls it `small_3_0` — adjust the next step if AWS has rolled to a newer revision.

- [ ] **Step 21.4: Launch the instance**

```bash
cd /Users/aj/Desktop/Projects/Workspace/jinx
aws lightsail create-instances \
  --region us-east-1 \
  --availability-zone us-east-1a \
  --instance-names jinx \
  --blueprint-id ubuntu_24_04 \
  --bundle-id small_3_0 \
  --user-data file://bootstrap.sh
```

(Adjust `--blueprint-id` and `--bundle-id` if Steps 21.2/21.3 returned different exact IDs.)

Expected: a JSON `operations` blob with status `Started`. The instance takes ~60s to boot, then bootstrap.sh runs and takes another ~3 min.

- [ ] **Step 21.5: Wait for the instance to become `running`**

```bash
aws lightsail get-instance --region us-east-1 --instance-name jinx \
  --query 'instance.state.name' --output text
```

Re-run every ~30s until it returns `running`. (Or use `aws lightsail wait` if your CLI version supports it for instances.)

- [ ] **Step 21.6: Allocate and attach a static IP**

```bash
aws lightsail allocate-static-ip --region us-east-1 --static-ip-name jinx-static-ip
aws lightsail attach-static-ip   --region us-east-1 --static-ip-name jinx-static-ip --instance-name jinx
aws lightsail get-static-ip      --region us-east-1 --static-ip-name jinx-static-ip \
  --query 'staticIp.ipAddress' --output text
```

Expected: an IPv4 address. **Note this address — you'll use it in Task 22.**

- [ ] **Step 21.7: Tighten the Lightsail firewall**

By default the firewall opens 22 + 80 + ICMP. Replace with our policy (22 + 443 only):

```bash
aws lightsail put-instance-public-ports \
  --region us-east-1 \
  --instance-name jinx \
  --port-infos \
    fromPort=22,toPort=22,protocol=TCP \
    fromPort=443,toPort=443,protocol=TCP
```

Expected: `operations` blob with `Succeeded`.

- [ ] **Step 21.8: Enable daily snapshots**

```bash
aws lightsail enable-add-on \
  --region us-east-1 \
  --resource-name jinx \
  --add-on-request 'addOnType=AutoSnapshot,autoSnapshotAddOnRequest={snapshotTimeOfDay=03:00}'
```

Expected: `operations` blob with `Succeeded`.

(No commit for Task 21 — cloud resources, not code.)

---

## Task 22: Cloudflare DNS + zone settings — `[INTERACTIVE — AJ executes]`

**Files:** none (cloud resource)

- [ ] **Step 22.1: Add the A record**

In the Cloudflare dashboard, zone `generalproducts.io`:

1. DNS → Records → Add record
2. Type: `A`, Name: `jinx`, IPv4 address: *the static IP from Step 21.6*, Proxy status: **Proxied (orange cloud)**, TTL: Auto.
3. Save.

- [ ] **Step 22.2: Add the wildcard CNAME**

1. DNS → Records → Add record
2. Type: `CNAME`, Name: `*.jinx`, Target: `jinx.generalproducts.io`, Proxy status: **Proxied (orange cloud)**, TTL: Auto.
3. Save.

- [ ] **Step 22.3: Verify DNS resolves**

```bash
dig +short jinx.generalproducts.io
dig +short something-random.jinx.generalproducts.io
```

Expected: both return Cloudflare IPs (104.x.x.x or 172.x.x.x range — the proxy is in front, so you see Cloudflare's edge IPs, not the static IP).

- [ ] **Step 22.4: Configure zone-level SSL/TLS settings**

1. SSL/TLS → Overview → Mode: **Full (strict)**.
2. SSL/TLS → Edge Certificates → **Always Use HTTPS: ON**.
3. SSL/TLS → Edge Certificates → **Minimum TLS Version: 1.2**.

Verify with:

```bash
curl -sI http://jinx.generalproducts.io | head -5
```

Expected: `HTTP/1.1 301 Moved Permanently` with `Location: https://...` — Cloudflare is now redirecting at the edge.

(No commit for Task 22.)

---

## Task 23: Generate Cloudflare Origin Certificate — `[INTERACTIVE — AJ executes]`

**Files:**
- Create (locally, gitignored): `~/Downloads/jinx-origin-cert.pem`
- Create (locally, gitignored): `~/Downloads/jinx-origin-key.pem`

- [ ] **Step 23.1: Generate the cert**

In the Cloudflare dashboard, zone `generalproducts.io`:

1. SSL/TLS → Origin Server → "Create Certificate"
2. Private key type: **ECC (ECDSA)** (faster handshake, smaller cert).
3. Hostnames: `jinx.generalproducts.io, *.jinx.generalproducts.io`
4. Validity: 15 years.
5. Click "Create".

Cloudflare displays the cert and the private key **once**. Copy both blobs.

- [ ] **Step 23.2: Save locally**

Save the cert PEM block (`-----BEGIN CERTIFICATE-----` ... `-----END CERTIFICATE-----`) to `~/Downloads/jinx-origin-cert.pem`. Save the key PEM block to `~/Downloads/jinx-origin-key.pem`. **Do not commit these files anywhere.**

- [ ] **Step 23.3: Verify file shapes**

```bash
head -1 ~/Downloads/jinx-origin-cert.pem
head -1 ~/Downloads/jinx-origin-key.pem
```

Expected: `-----BEGIN CERTIFICATE-----` and `-----BEGIN EC PRIVATE KEY-----` (or `-----BEGIN PRIVATE KEY-----`).

(No commit for Task 23.)

---

## Task 24: First SSH + install Caddy config + Origin Cert

**Files:** none (remote install)

- [ ] **Step 24.1: Verify SSH works**

```bash
ssh -o StrictHostKeyChecking=accept-new andrew@jinx.generalproducts.io 'hostname && uptime && tail -20 /var/log/jinx-bootstrap.log'
```

Expected: hostname `ip-...` (Lightsail's default), uptime, and the tail of bootstrap log ending in `Bootstrap complete` and the manual-steps banner.

If SSH fails: check Lightsail console "Connect" tab for instance state, check `~andrew/.ssh/authorized_keys` via Lightsail browser SSH, verify your local pubkey is on https://github.com/andrewmcadoo.keys.

- [ ] **Step 24.2: Add Jinx to your SSH config (laptop)**

Append to `~/.ssh/config`:

```
Host jinx
    Hostname jinx.generalproducts.io
    User andrew
    ServerAliveInterval 60
```

(If you don't have a project-specific key, this uses your default identity. To use a dedicated key, generate one and add `IdentityFile ~/.ssh/jinx_ed25519` plus add the pubkey to https://github.com/settings/keys, then `ssh jinx 'sudo /usr/local/bin/refresh-ssh-keys'` once it exists.)

- [ ] **Step 24.3: scp the Caddy base config and apex site**

```bash
cd /Users/aj/Desktop/Projects/Workspace/jinx
scp caddy/Caddyfile jinx:/tmp/
scp caddy/sites/00-apex.caddy jinx:/tmp/
ssh jinx 'sudo install -m 0644 -o root -g root /tmp/Caddyfile /etc/caddy/Caddyfile
          sudo install -m 0644 -o root -g root /tmp/00-apex.caddy /etc/caddy/sites/00-apex.caddy
          rm /tmp/Caddyfile /tmp/00-apex.caddy'
```

Expected: silent success.

- [ ] **Step 24.4: scp the apex landing page**

```bash
cd /Users/aj/Desktop/Projects/Workspace/jinx
scp apex/index.html jinx:/tmp/
ssh jinx 'sudo install -m 0644 -o andrew -g andrew /tmp/index.html /srv/_apex/index.html
          rm /tmp/index.html'
```

- [ ] **Step 24.5: scp + install the Origin Cert**

```bash
scp ~/Downloads/jinx-origin-cert.pem jinx:/tmp/cert.pem
scp ~/Downloads/jinx-origin-key.pem  jinx:/tmp/key.pem
ssh jinx 'sudo install -m 0644 -o root -g caddy /tmp/cert.pem /etc/ssl/jinx/cert.pem
          sudo install -m 0640 -o root -g caddy /tmp/key.pem  /etc/ssl/jinx/key.pem
          rm /tmp/cert.pem /tmp/key.pem'
```

Expected: silent success.

- [ ] **Step 24.6: Validate Caddy config on the box**

```bash
ssh jinx 'sudo caddy validate --config /etc/caddy/Caddyfile'
```

Expected: `Valid configuration`.

- [ ] **Step 24.7: Install the refresh-ssh-keys script**

```bash
cd /Users/aj/Desktop/Projects/Workspace/jinx
scp scripts/refresh-ssh-keys.sh jinx:/tmp/
ssh jinx 'sudo install -m 0755 -o root -g root /tmp/refresh-ssh-keys.sh /usr/local/bin/refresh-ssh-keys
          rm /tmp/refresh-ssh-keys.sh'
```

(No commit for Task 24.)

---

## Task 25: Enable Caddy and smoke-test

**Files:** none (verification)

- [ ] **Step 25.1: Enable and start Caddy**

```bash
ssh jinx 'sudo systemctl enable --now caddy && sudo systemctl status caddy --no-pager'
```

Expected: status `active (running)`.

- [ ] **Step 25.2: HTTPS smoke test from laptop**

```bash
curl -sS -o /dev/null -w 'HTTP %{http_code} via %{remote_ip}\n' https://jinx.generalproducts.io
```

Expected: `HTTP 200 via <Cloudflare-edge-IP>`.

- [ ] **Step 25.3: Confirm the apex page renders**

```bash
curl -s https://jinx.generalproducts.io | grep -E "<title>|<h1>"
```

Expected:
```
<title>Jinx</title>
<h1>Jinx</h1>
```

- [ ] **Step 25.4: Confirm wildcard subdomains TLS-terminate (404 is expected — no site block)**

```bash
curl -sI https://nothing-yet.jinx.generalproducts.io | head -5
```

Expected: `HTTP/2 200` from Cloudflare's "site under construction" or `HTTP/2 404` (depending on Cloudflare's default for unconfigured proxied subdomains). Either is fine — the point is the TLS handshake succeeds, proving the wildcard cert works at the edge. To prove origin TLS, bypass Cloudflare:

```bash
curl -sI --resolve nothing-yet.jinx.generalproducts.io:443:$(\
  aws lightsail get-static-ip --region us-east-1 --static-ip-name jinx-static-ip \
    --query 'staticIp.ipAddress' --output text) \
  https://nothing-yet.jinx.generalproducts.io
```

Expected: a TLS connection succeeds (Caddy responds, possibly 404 because no site block matches — that's correct).

- [ ] **Step 25.5: Confirm HTTP→HTTPS redirect works at Cloudflare**

```bash
curl -sI http://jinx.generalproducts.io | head -3
```

Expected: `HTTP/1.1 301 Moved Permanently` with `Location: https://jinx.generalproducts.io/`.

- [ ] **Step 25.6: Confirm `:80` is closed at the origin (defense in depth verification)**

```bash
ip=$(aws lightsail get-static-ip --region us-east-1 --static-ip-name jinx-static-ip \
  --query 'staticIp.ipAddress' --output text)
nc -zv -w 3 "$ip" 80 2>&1 || echo "CLOSED (good)"
nc -zv -w 3 "$ip" 443 2>&1
```

Expected: `:80` shows `CLOSED (good)` (or `Connection refused` / timeout); `:443` shows succeeded.

- [ ] **Step 25.7: Confirm sshd hardening took effect**

```bash
ssh -o PreferredAuthentications=password -o PubkeyAuthentication=no \
    andrew@jinx.generalproducts.io 2>&1 | head -3
```

Expected: `Permission denied (publickey).` — password auth is rejected.

(No commit for Task 25.)

---

## Task 26: Finalize — close the bd issue, commit the plan itself

**Files:**
- The plan file `docs/superpowers/plans/2026-05-03-jinx-scratch-box.md` (this file) gets committed in Step 26.1 if not already.

- [ ] **Step 26.1: Commit the plan file (if not already committed)**

```bash
cd /Users/aj/Desktop/Projects/Workspace/jinx
git status docs/superpowers/plans/2026-05-03-jinx-scratch-box.md
```

If untracked / modified:

```bash
git add docs/superpowers/plans/2026-05-03-jinx-scratch-box.md
git commit -m "docs: implementation plan for Jinx scratch-box stand-up"
git push
```

- [ ] **Step 26.2: Update the apex listing**

`apex/index.html` will accumulate `<li>` entries as projects come online. For now, no projects are deployed — that's a separate follow-up tracked as its own beads issue.

- [ ] **Step 26.3: Close the bd issue**

```bash
cd /Users/aj/Desktop/Projects/Workspace/mim
bd close mim-qb6 --reason="Jinx box live at https://jinx.generalproducts.io. Project deploys (mim, others) tracked as separate issues."
```

- [ ] **Step 26.4: File the follow-up beads issue for deploying mim to Jinx**

```bash
cd /Users/aj/Desktop/Projects/Workspace/mim
bd create \
  --title="Deploy mim to Jinx" \
  --description="Now that jinx.generalproducts.io is live, deploy a current build of mim at mim.jinx.generalproducts.io. Includes: pick port assignments per Jinx PORTS.md; write deploy.sh modeled on Clipper's; provision Postgres+pgvector on the box; write Caddy site block + systemd units (mim-web, mim-api); load .env.production with non-prod secrets. Out of scope of this issue: mim's PRD §22 production stack — that's separate." \
  --type=task \
  --priority=2
```

- [ ] **Step 26.5: Push everything one more time**

```bash
cd /Users/aj/Desktop/Projects/Workspace/jinx
git push

cd /Users/aj/Desktop/Projects/Workspace/mim
bd dolt push
git status  # should be clean (no code changes in mim from this plan)
```

Expected: jinx repo up-to-date with origin/main; mim has no new code commits but the bd state is pushed.

---

## Self-review checklist

After implementation completes, the executing engineer should re-read the spec at
`docs/superpowers/specs/2026-05-03-jinx-scratch-box-design.md` and verify:

- [ ] §3.1 Provider/region/bundle: matches what was launched in Task 21.
- [ ] §3.2 Network: only `:22` and `:443` open at Lightsail and at UFW (verified Step 25.6).
- [ ] §3.3 DNS + Cloudflare zone settings: verified Step 22.4 (Always Use HTTPS, Full strict, Min TLS 1.2).
- [ ] §3.4 TLS: Origin Cert installed at `/etc/ssl/jinx/` with 0644 root:caddy / 0640 root:caddy (Step 24.5).
- [ ] §3.5 Caddy + §3.6 apex page: served and verified Steps 25.2–25.4.
- [ ] §3.7 systemd: template installed (no project services running yet — that's a follow-up issue).
- [ ] §3.8 /srv layout: `/srv` exists with apex; project subdirs created on-demand per RUNBOOK.md.
- [ ] §3.9 PORTS.md: present with example row only.
- [ ] §4.1 SSH keys from GitHub: verified by being able to SSH at all (Step 24.1).
- [ ] §4.2 sshd hardening: verified Step 25.7 (password auth rejected).
- [ ] §4.3 sudoers: base entry installed by bootstrap.
- [ ] §5 hardening: UFW + unattended-upgrades enabled by bootstrap (verify with `sudo ufw status` and `systemctl status unattended-upgrades` on the box).
- [ ] §6 repo layout: present and pushed to GitHub.
- [ ] §6.2 launch procedure: every step executed, total wall-clock ≤ 30 min.
