# Jinx — bootstrap rework

**Status:** Design, awaiting approval
**Date:** 2026-05-11
**Owner:** AJ (`andrewmcadoo`)
**Supersedes parts of:** `2026-05-03-jinx-scratch-box-design.md` §6 (Launch procedure) and `bootstrap.sh`

## 1. Summary

The current `bootstrap.sh` is a ~300-line monolith that runs as Lightsail
cloud-init user-data and leaves the box in a partially-configured state —
five manual `scp`/`ssh` steps still stand between "bootstrap finished" and
"box is serving traffic." A separate problem surfaced on 2026-05-11: the
box's 60 GB root disk filled to 100% because nothing rotates Caddy logs or
prunes release dirs and there is no health monitoring.

This rework replaces `bootstrap.sh` with a thin orchestrator that
`git clone`s this repo to `/opt/jinx` and execs a chain of per-concern
install scripts. The same chain re-runs cleanly on snapshot restore or
manual re-invocation, picking up any config changes committed to the
repo since first boot. Post-bootstrap surface drops from ~8 manual
steps to 2 (real Cloudflare Origin Cert + Healthchecks URL).

## 2. Non-goals

- **Project deployments.** This rework only touches first-boot
  configuration. The 12-step RUNBOOK §"Adding a project" flow is
  unchanged.
- **Migration tooling for existing project data.** The cutover wipes
  the existing box. Project state (`.env.production` files, release
  dirs, project DBs) is intentionally discarded — operator confirmed
  scratch tier with nothing worth saving.
- **Cloudflare Origin Cert automation.** Issuing certs remains a
  manual Cloudflare-dashboard operation. Bootstrap reduces friction by
  installing a self-signed placeholder so Caddy starts cleanly; the
  real cert is `scp`'d in afterward as the one remaining manual step.
- **IaC migration.** Still no Terraform/Pulumi. The launch procedure
  remains a documented `aws lightsail create-instances` invocation.
- **Multi-host or HA.** Single-box scratch tier unchanged.

## 3. Pain points addressed

| Today | After |
|---|---|
| Disk fills with no rotation/monitoring → 2026-05-11 outage | Caddy built-in log rolling (tuned aggressive), journald cap (500 MB), nightly release-prune cron, Healthchecks.io heartbeat every 15 min |
| 5 `scp`/`ssh` steps after bootstrap before box serves | 1 mandatory `scp` (real cert), 1 optional config write (Healthchecks URL) |
| `refresh-ssh-keys.sh` in repo but not installed; RUNBOOK assumes it exists at `/usr/local/bin/` | Installed by `install/70-helpers.sh` |
| Bootstrap can "succeed" while leaving box broken (no smoke test) | `install/90-verify.sh` asserts ufw enabled, sshd valid, Caddy active, `curl https://127.0.0.1` returns 200, disk <90%, no failed units |
| `AllowUsers andrew` lives in both `bootstrap.sh` and `sshd/90-jinx.conf` (drift risk) | Repo file is single source of truth; install script copies it |
| No baseline operator tooling (`tmux`/`htop`/`jq`/`rsync`) | Installed by `install/10-packages.sh` |
| Caddy `restart`-vs-`reload` quirk documented but not encoded | `jinx-caddy-apply` wrapper enforces the right action |
| `userdata.sh` could drift from `bootstrap.sh` without notice | GitHub Actions job runs `make-userdata.sh` and diffs against committed file |

## 4. Architecture

### 4.1 New repo layout

```
jinx/
├── bootstrap.sh                    # thin orchestrator (~80 lines)
├── userdata.sh                     # regenerated from bootstrap.sh (unchanged contract)
├── scripts/
│   ├── make-userdata.sh            # unchanged
│   ├── refresh-ssh-keys.sh         # unchanged (now installed by bootstrap)
│   └── test-bootstrap-local.sh     # NEW: Docker-based smoke test
├── install/                        # NEW: per-concern install steps
│   ├── lib.sh                      #   shared log()/retry() helpers
│   ├── run.sh                      #   orchestrates the 10..90 scripts
│   ├── 10-packages.sh
│   ├── 20-ufw.sh
│   ├── 30-user.sh
│   ├── 40-sshd-sudo.sh
│   ├── 50-filesystem.sh
│   ├── 60-caddy.sh
│   ├── 70-helpers.sh
│   ├── 80-monitoring.sh
│   └── 90-verify.sh
├── helpers/                        # NEW: source files for /usr/local/bin/jinx-*
│   ├── jinx-status
│   ├── jinx-caddy-apply
│   ├── jinx-prune-releases
│   └── jinx-healthcheck-ping
├── monitoring/                     # NEW: cron/journald config templates
│   ├── journald-jinx.conf
│   ├── cron-healthchecks
│   └── cron-prune-releases
├── caddy/                          # existing, now with tuned log-rolling snippet
├── sshd/, sudoers/, systemd/, apex/, docs/, JINX.md, PORTS.md, RUNBOOK.md
```

### 4.2 Boot flow

1. Lightsail runs `userdata.sh` (POSIX-safe wrapper) → unpacks
   `bootstrap.sh` to `/root/jinx-bootstrap.sh` → `exec bash` on it.
2. `bootstrap.sh` installs minimal prereqs (`ca-certificates`, `curl`,
   `git`), then `git clone`s `https://github.com/andrewmcadoo/jinx`
   into `/opt/jinx` at the ref in `$JINX_REF` (default `main`). On
   re-run, `git fetch + checkout + pull --ff-only` instead.
3. `bootstrap.sh` execs `/opt/jinx/install/run.sh`.
4. `run.sh` sources `install/lib.sh`, then invokes each `NN-*.sh` in
   numeric order under `set -euo pipefail` + an `ERR` trap that logs
   the failing step.
5. `90-verify.sh` exits non-zero if any baseline invariant is broken
   → cloud-init reports the bootstrap as failed.

### 4.3 Configuration knobs

Environment variables read by `bootstrap.sh` (all optional, defaults
in parentheses):

| Var | Default | Purpose |
|---|---|---|
| `JINX_REPO` | `https://github.com/andrewmcadoo/jinx.git` | Repo to clone |
| `JINX_REF` | `main` | Branch, tag, or commit |
| `JINX_NOPASSWD` | unset (0) | If `1`, install `sudoers/01-andrew-nopasswd` alongside `00-andrew`. Useful when iterating on box config; remove file by hand once iteration is done (per RUNBOOK §"Developer convenience"). |

## 5. Install steps

Each step is idempotent, sources `install/lib.sh` for `log()` and
`retry()`, runs as root, and exits non-zero on unrecoverable error.

### 5.1 `10-packages.sh`

- `apt-get update` (retried 3× with 5 s back-off).
- Install baseline: `ca-certificates curl gnupg ufw unattended-upgrades git`.
- Install operator tools: `tmux htop jq rsync vim-tiny ncdu less`.
- Add Cloudsmith Caddy apt repo (only if `caddy` not already present);
  `apt-get update` again; install `caddy`.
- Drop in `/etc/apt/apt.conf.d/20auto-upgrades` and
  `/etc/apt/apt.conf.d/52unattended-upgrades-jinx` (04:00 UTC
  auto-reboot). `systemctl enable --now unattended-upgrades`.

Language runtimes (Node, Bun, Python, Go) are **not** installed —
project-scoped per existing deploy patterns.

### 5.2 `20-ufw.sh`

- `ufw --force reset`; deny incoming, allow outgoing.
- Allow `22/tcp` (SSH), `443/tcp` (HTTPS).
- `ufw --force enable`. (Unchanged from current `configure_ufw`.)

### 5.3 `30-user.sh`

- `useradd --create-home --shell /bin/bash --groups sudo andrew` (no-op
  if user exists); re-assert sudo group membership on every run.
- Pull `https://github.com/andrewmcadoo.keys` (3-retry,
  algorithm-validated) → install to `~andrew/.ssh/authorized_keys`
  mode 0600.

### 5.4 `40-sshd-sudo.sh`

- Copy `sshd/90-jinx.conf` → `/etc/ssh/sshd_config.d/90-jinx.conf`.
  Validate with `sshd -t` before reload.
- Copy `sudoers/00-andrew` → `/etc/sudoers.d/00-andrew` (visudo-checked).
- If `$JINX_NOPASSWD == 1`: copy `sudoers/01-andrew-nopasswd` →
  `/etc/sudoers.d/01-andrew-nopasswd` (visudo-checked).
- `systemctl reload ssh`.

The current `bootstrap.sh` heredoc-duplication of these files is
eliminated.

### 5.5 `50-filesystem.sh`

- Create `/srv` (andrew-owned), `/srv/_apex`, `/etc/caddy/sites`
  (root), `/etc/ssl/jinx` (root:caddy 0750), `/var/log/caddy`
  (caddy:caddy).
- Pre-create `/var/log/caddy/caddy.log` and `/var/log/caddy/apex.log`
  with caddy ownership. Auto-discover existing per-site logs by
  parsing `output file …` directives in `/etc/caddy/sites/*.caddy`
  (preserves current snapshot-restore behavior).

### 5.6 `60-caddy.sh`

- Copy `caddy/Caddyfile` → `/etc/caddy/Caddyfile`.
- Copy `caddy/sites/00-apex.caddy` → `/etc/caddy/sites/`.
- Copy `apex/index.html` → `/srv/_apex/index.html` only if the file is
  missing or matches a known placeholder fingerprint (never clobbers a
  real deployed apex page on re-runs).
- TLS cert flow:
  ```bash
  if [[ -f /etc/ssl/jinx/cert.pem && -f /etc/ssl/jinx/key.pem ]] \
     && openssl x509 -in /etc/ssl/jinx/cert.pem -noout -checkend 0 >/dev/null 2>&1; then
      log "TLS: existing cert is valid, preserving"
  else
      log "TLS: generating self-signed placeholder (30-day P-256)"
      openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 \
          -keyout /etc/ssl/jinx/key.pem -out /etc/ssl/jinx/cert.pem \
          -sha256 -days 30 -nodes \
          -subj "/CN=jinx.generalproducts.io/O=Jinx Self-Signed Placeholder" \
          -addext "subjectAltName=DNS:jinx.generalproducts.io,DNS:*.jinx.generalproducts.io"
      chown root:caddy /etc/ssl/jinx/cert.pem /etc/ssl/jinx/key.pem
      chmod 0644 /etc/ssl/jinx/cert.pem
      chmod 0640 /etc/ssl/jinx/key.pem
  fi
  ```
- `caddy validate --config /etc/caddy/Caddyfile`.
- `systemctl enable --now caddy`.

The self-signed cert lets Caddy serve `https://127.0.0.1/`
successfully so `90-verify.sh` passes, but Cloudflare's "Full
(strict)" mode will return 526 to the edge until the real Origin Cert
replaces it.

### 5.7 `70-helpers.sh`

Copy each file to `/usr/local/bin/` (mode 0755, root-owned):

- `helpers/jinx-status` — health snapshot: uptime, load, disk%, mem%,
  failed units count, caddy status, cert subject + expiry, list of
  `/srv/*` (excluding `_apex`) with their unit status.
- `helpers/jinx-caddy-apply` — `caddy validate` then
  `systemctl restart caddy` (encodes the `restart`-not-`reload` rule
  from RUNBOOK).
- `helpers/jinx-prune-releases` — `--keep N` (default 5). For each
  `/srv/*/releases/`, keeps newest N by mtime, deletes older. Skips
  the target of `current` symlink. Skips paths without a `releases/`
  subdir. Supports `--dry-run` and `--project NAME` (limit to one
  project tree).
- `helpers/jinx-healthcheck-ping` — reads URL from
  `/etc/jinx/healthchecks-url` (if present), POSTs disk%, load,
  failed-units count.
- `scripts/refresh-ssh-keys.sh` → `/usr/local/bin/refresh-ssh-keys`
  (existing script, just installed).

### 5.8 `80-monitoring.sh`

- Copy `monitoring/journald-jinx.conf` →
  `/etc/systemd/journald.conf.d/jinx.conf`:
  ```
  [Journal]
  SystemMaxUse=500M
  SystemMaxFileSize=50M
  MaxRetentionSec=2week
  ```
  `systemctl restart systemd-journald`.
- Copy `monitoring/cron-prune-releases` →
  `/etc/cron.daily/jinx-prune-releases` (mode 0755):
  ```sh
  #!/bin/sh
  exec /usr/local/bin/jinx-prune-releases --keep 3
  ```
- Copy `monitoring/cron-healthchecks` → `/etc/cron.d/jinx-healthchecks`:
  ```
  */15 * * * * root /usr/local/bin/jinx-healthcheck-ping
  ```
  The ping helper silently no-ops if `/etc/jinx/healthchecks-url` is
  absent — bootstrap doesn't fail when no URL is configured yet.

**No external Caddy logrotate.** Caddy v2's `output file` directive
already implements size-based rolling. The base `caddy/Caddyfile`
gains a snippet that all per-site files import:

```caddy
(common_log) {
    log {
        output file /var/log/caddy/{args[0]}.log {
            roll_size 50mb
            roll_keep 5
            roll_keep_for 168h
        }
    }
}
```

Each site uses `import common_log <site-name>`. With ~6 sites at the
50 MB × 5-keep ceiling, Caddy log usage is bounded at ~1.5 GB.

### 5.9 `90-verify.sh`

Assert and exit non-zero on first failure:

1. `ufw status | grep -q 'Status: active'`.
2. UFW shows allow rules for 22 and 443.
3. `sshd -t` passes.
4. `visudo -cf /etc/sudoers.d/00-andrew` passes.
5. `caddy validate --config /etc/caddy/Caddyfile` passes.
6. `systemctl is-active caddy` == `active`.
7. `curl -ksI https://127.0.0.1/ -o /dev/null -w '%{http_code}'` == `200`.
8. `df --output=pcent / | tail -1 | tr -dc 0-9` < `90`.
9. `systemctl --failed --no-legend | wc -l` == `0`.
10. `id andrew` succeeds and andrew is in the sudo group.
11. `/usr/local/bin/jinx-status` exists and is executable.

Logs the final two lines:
`[verify] all checks passed` or `[verify] FAILED: <which one>`.

## 6. Operator helpers — interface contracts

| Helper | Args | Exits non-zero on |
|---|---|---|
| `jinx-status` | none | never (informational) |
| `jinx-caddy-apply` | none | `caddy validate` failure, `systemctl restart` failure |
| `jinx-prune-releases` | `[--keep N]` `[--dry-run]` `[--project NAME]` | unwritable filesystem; never on "nothing to prune" |
| `jinx-healthcheck-ping` | none | network failure POSTing to Healthchecks URL (cron silences via local MTA or nothing) |
| `refresh-ssh-keys` | none | invalid keys from GitHub after 3 retries |

## 7. Idempotency and re-run semantics

- `bootstrap.sh` re-run does `git fetch + checkout $JINX_REF + pull
  --ff-only` then re-execs `install/run.sh`. **Snapshot-restored
  boxes self-heal toward the current repo state.**
- File installs use `install(1)` (atomic owner/group/mode) or
  declarative-overwrite (heredoc-style `cat >`). Operator changes to
  managed files are overwritten on re-run — desirable: declared state
  wins.
- Three exceptions to declarative-overwrite:
  1. `/etc/ssl/jinx/cert.pem` + `key.pem` — preserved if valid; only
     missing/expired triggers placeholder regeneration.
  2. `/srv/_apex/index.html` — overwritten only if file matches
     placeholder fingerprint or is absent.
  3. `/var/log/caddy/*.log` — pre-created only if missing; never
     truncated.

## 8. Error handling

- `set -euo pipefail` everywhere; `IFS=$'\n\t'` in `run.sh`.
- `run.sh` installs `ERR` trap that logs
  `step <NN-name> failed at line <L>: <last_command>` to
  `/var/log/jinx-bootstrap.log` before exiting non-zero.
- Network operations (`apt-get update`, `git clone`, `curl
  github.com/.keys`) wrapped in `retry()` (3 attempts, 5 s sleep).
- `sshd -t` and `visudo -cf` validate **before** install, mirroring
  current behavior — bad sshd or sudoers config cannot brick the box.
- A failed `90-verify.sh` exits the whole bootstrap non-zero so
  cloud-init records the failure; operator reads
  `/var/log/jinx-bootstrap.log` via Lightsail browser console.

## 9. Testing

Before the existing `jinx` box is ever wiped:

1. **shellcheck CI** extended to lint `bootstrap.sh`, `install/run.sh`,
   `install/*.sh`, `helpers/jinx-*`, `monitoring/cron-*`. Build fails
   on any warning.
2. **`userdata.sh` drift CI** — new GitHub Actions job runs
   `scripts/make-userdata.sh` in a temp dir and `git diff --exit-code
   userdata.sh`. Catches "edited bootstrap.sh without regenerating".
3. **`scripts/test-bootstrap-local.sh`** — new Docker-based smoke
   test:
   - Builds throwaway Ubuntu 24.04 container.
   - Mounts the repo at `/opt/jinx`; sets `JINX_DIR=/opt/jinx` env to
     skip the `git clone` step.
   - Runs `install/run.sh` + `90-verify.sh`.
   - Asserts caddy up, apex returns 200, self-signed cert valid.
   - ~60 s wall time. Documented in CONTRIBUTING-style note;
     not in CI by default (requires Docker).
4. **Lightsail test-instance bake-off**:
   - Create `jinx-test` from the new `userdata.sh`.
   - SSH, run `jinx-status`, eyeball.
   - If green: proceed to cutover. If red: iterate; the existing
     `jinx` keeps serving (badly) in the meantime.

## 10. Cutover procedure (wiping the existing box)

> Static IP `23.23.181.232` is the load-bearing piece. As long as it
> ends up attached to the new instance, DNS continues to resolve
> correctly.

1. Verify `jinx-test` passed all checks.
2. Lightsail console: detach `23.23.181.232` from existing `jinx`.
   Cloudflare starts returning 521 for `jinx.generalproducts.io`.
3. Delete existing `jinx` instance.
4. `scripts/make-userdata.sh` to refresh the artifact (sanity).
5. ```
   aws lightsail create-instances \
     --instance-names jinx \
     --availability-zone us-east-1a \
     --bundle-id small_3_0 \
     --blueprint-id ubuntu_24_04 \
     --user-data file://userdata.sh \
     --tags key=tier,value=scratch key=project,value=jinx
   ```
6. Wait for `state=running`; attach `23.23.181.232`.
7. `ssh jinx 'sudo tail -200 /var/log/jinx-bootstrap.log'` — confirm
   `bootstrap OK` and `[verify] all checks passed`.
8. `ssh jinx 'jinx-status'` — eyeball.
9. `scp cert.pem key.pem jinx:/tmp/ && ssh jinx 'sudo install -m 0644
   -o root -g caddy /tmp/cert.pem /etc/ssl/jinx/cert.pem && sudo
   install -m 0640 -o root -g caddy /tmp/key.pem /etc/ssl/jinx/key.pem
   && sudo jinx-caddy-apply && rm /tmp/cert.pem /tmp/key.pem'`.
10. `curl -I https://jinx.generalproducts.io` — expect 200.
11. (Optional) `echo "https://hc-ping.com/<uuid>" | sudo tee
    /etc/jinx/healthchecks-url` to wire monitoring.

## 11. Out-of-scope follow-ups

These could happen later but are explicitly not part of this rework:

- Automated CF Origin Cert pull from SSM Parameter Store / Secrets
  Manager (would eliminate the one remaining manual `scp` step).
- `jinx-add-project` interactive scaffolder (the 12-step RUNBOOK
  flow stays manual).
- Migration of `/srv` to a separate Lightsail attached disk
  (decouples app data from instance lifecycle).
- Fail2ban or sshguard layering on top of key-only SSH.
- Per-project sudoers entry generator that codifies the
  `sudoers/<project>` pattern from RUNBOOK §"Adding a project" step 8.

## 12. Decisions and trade-offs

| Decision | Why this option | What we give up |
|---|---|---|
| Orchestrator + per-concern scripts (vs monolith / ansible-pull) | Each step is shellcheck-clean, idempotent, locally Docker-testable | One file becomes two directories |
| `git clone` public repo at boot (vs embed everything inline / S3 / Ansible) | No auth, no secrets, repo is the single source of truth, drift catches up on re-run | Requires public-repo network availability during cloud-init (mitigated by 3-retry) |
| Self-signed placeholder + manual real-cert `scp` (vs SSM-stored cert / mTLS / unchanged) | Caddy starts cleanly at boot, `90-verify.sh` passes, no AWS-IAM complexity for a scratch box | One manual step survives; CF returns 526 until operator replaces cert |
| Caddy built-in `output file` rolling, tuned tight (vs `/etc/logrotate.d/caddy`) | Avoids dual-rotation conflict; single source of truth in Caddyfile snippet | External `journalctl`-style tooling won't see "the" rotated files in a standard location |
| Healthchecks.io heartbeat (vs CloudWatch / local mail) | Free, no AWS surface, alerting works out of the box, ~20 lines of helper | Vendor dependency; URL is a secret-ish thing in `/etc/jinx/` |
| Bun/Node stay project-scoped (vs baseline) | Cleaner separation, no version drift between projects, smaller bootstrap | Each project's deploy must provision its own runtime |
| `JINX_NOPASSWD=1` env flag (vs always-on / always-off) | Iterating operator gets convenience without it being the default | One more knob to remember |
