# Jinx — scratch deployment box

**Status:** Design, awaiting approval
**Date:** 2026-05-03
**Owner:** AJ (`andrewmcadoo`)
**Tracking:** beads issue `mim-qb6`

## 1. Summary

Jinx is a single AWS Lightsail VM that hosts personal and team development
projects under subdomains of `jinx.generalproducts.io`. It is the cheap,
SSH-deployed, "scratch tier" — explicitly **not** the production target for any
project that gains real traction. Inspired by `clipper.speedero.com` (release-dir
layout, atomic symlink swap, systemd-supervised processes, GitHub-Actions
deploys), generalized so a single box can host many projects with full origin
isolation.

A project named `foo` lands at `https://foo.jinx.generalproducts.io`. Adding a
new project costs a Cloudflare CNAME, a Caddy site file, and a systemd unit.

## 2. Non-goals

- **Production hosting for mim or any other project that proves itself.** mim's
  production stack remains as locked in `mim/IMPLEMENTATION_PLAN.md` and
  `mim/docs/PRD.md` §22 (ECS Fargate + RDS Multi-AZ + CloudFront + SST). When a
  project graduates from scratch tier, it migrates off Jinx to its own
  dedicated infrastructure.
- **Multi-tenant isolation between teammates.** All work happens as a single
  Linux user (`andrew`) on a shared box. This is fine for a scratch tier with a
  small trusted team. Per-teammate Linux accounts are deferred until a teammate
  beyond AJ actually exists.
- **Horizontal scale, HA, multi-region.** One box, one region, daily snapshot.
- **IaC.** A single Lightsail instance does not justify Terraform/Pulumi/SST.
  The launch procedure is documented as a runbook + a bootstrap shell script.
- **Cloudflare Tunnel / SSO-fronted SSH.** Plain SSH on port 22 with key-only
  auth is sufficient for the scratch tier. Tunnel migration is a documented
  future option.

## 3. Architecture

### 3.1 Provider and instance

- **Provider:** AWS Lightsail (chosen over EC2 for simplicity; chosen over
  Hetzner/DO because AWS branding was a soft preference and Lightsail removes
  VPC/SG/EIP plumbing while staying in AWS).
- **Region:** `us-east-1`, AZ `us-east-1a`.
- **Bundle:** Linux `small_3_0` ($10/mo, 2 GB RAM, 2 vCPU, 60 GB SSD, 3 TB
  egress). Verify exact bundle ID at launch with
  `aws lightsail get-bundles --region us-east-1`.
- **OS image:** `ubuntu_24_04` (Ubuntu 24.04 LTS).
- **Static IP:** named `jinx-static-ip`, attached to the instance. Free while
  attached to a running instance.
- **Snapshots:** Lightsail auto-snapshot daily at 03:00 UTC, retain 7. Manual
  snapshot taken before any risky change.

### 3.2 Network

Lightsail firewall (instance-level), inbound only:

| Port    | Protocol | Source        | Purpose                                |
| ------- | -------- | ------------- | -------------------------------------- |
| 22      | TCP      | `0.0.0.0/0`   | SSH (key-only, see §4)                 |
| 443     | TCP      | `0.0.0.0/0`   | HTTPS                                  |

All other inbound denied — including **port 80**. Cloudflare's "Always Use
HTTPS" page rule rewrites `http://` to `https://` at the edge before
connecting to origin, so HTTP traffic never reaches Jinx and a `:80`
listener is unnecessary. If the Cloudflare proxy is ever disabled (gray
cloud), open `:80` and add an HTTP-only Caddy block that redirects to HTTPS
before changing DNS.

Outbound unrestricted.

UFW configured identically as a second layer (defense in depth). Default deny
inbound, default allow outbound.

### 3.3 DNS (Cloudflare)

`generalproducts.io` is registered at and DNS-hosted by Cloudflare.

| Record                              | Type  | Value                       | Proxy  |
| ----------------------------------- | ----- | --------------------------- | ------ |
| `jinx.generalproducts.io`           | A     | `<jinx-static-ip>`          | ON     |
| `*.jinx.generalproducts.io`         | CNAME | `jinx.generalproducts.io`   | ON     |

Per-project subdomains do **not** need their own DNS records — the wildcard
covers them. They only need a Caddy site block (§3.5).

Cloudflare SSL/TLS mode: **Full (strict)**. Browser ↔ Cloudflare uses
Cloudflare's edge cert; Cloudflare ↔ Jinx uses the Origin Certificate (§3.4).

Cloudflare zone settings required at launch:

- **SSL/TLS → Edge Certificates → Always Use HTTPS:** ON (load-bearing — see
  §3.2 for why port 80 is closed at origin)
- **SSL/TLS → Edge Certificates → Minimum TLS Version:** 1.2 or 1.3
- **SSL/TLS → Overview → mode:** Full (strict)

### 3.4 TLS

A single **Cloudflare Origin Certificate** covers `jinx.generalproducts.io`
and `*.jinx.generalproducts.io`. 15-year validity, RSA 2048 or ECDSA P-256.

Generation is manual (Cloudflare dashboard → SSL/TLS → Origin Server → Create
Certificate). The Origin Certificate API requires an Origin CA Key (a separate
Cloudflare credential type, not a regular API token), so manual generation via
the dashboard is the lowest-friction path for a one-time install. Cert + key
dropped on Jinx at:

```
/etc/ssl/jinx/cert.pem    # 0644 root:caddy
/etc/ssl/jinx/key.pem     # 0640 root:caddy
```

(Group `caddy` is created by the official Caddy apt package. Group-readable
key with restrictive group is the standard pattern for system services that
need TLS keys without running as root.)

Caddy reads them via `tls /etc/ssl/jinx/cert.pem /etc/ssl/jinx/key.pem` in
each site block. No ACME on the box (Cloudflare handles edge certs;
Origin Cert is a one-shot install).

Renewal in 2041. A Lightsail snapshot before expiry preserves the existing
cert; rotation is "regenerate in dashboard, scp, reload caddy."

### 3.5 Reverse proxy: Caddy

Caddy 2.x from the official Cloudsmith apt repo. Installed and enabled at
boot via the bootstrap script.

Layout:

```
/etc/caddy/Caddyfile          # base config; just imports sites/
/etc/caddy/sites/
  00-apex.caddy               # jinx.generalproducts.io landing page
  mim.caddy                   # mim.jinx.generalproducts.io
  poke-view.caddy             # poke-view.jinx.generalproducts.io
  ...
```

`Caddyfile`:

```
{
    admin off
    # auto_https off disables both ACME issuance AND HTTP→HTTPS redirect.
    # We don't need either: certs come from Cloudflare Origin (§3.4), and
    # HTTP→HTTPS happens at Cloudflare's edge before traffic reaches us
    # (§3.2 + §3.3 "Always Use HTTPS").
    auto_https off
}

import sites/*.caddy
```

A typical project site block:

```
mim.jinx.generalproducts.io {
    tls /etc/ssl/jinx/cert.pem /etc/ssl/jinx/key.pem

    # API on path; rest goes to the web frontend
    handle /api/* {
        reverse_proxy localhost:3101
    }
    handle {
        reverse_proxy localhost:3001
    }

    log {
        output file /var/log/caddy/mim.log
        format json
    }
}
```

Adding a project = drop a new file in `/etc/caddy/sites/` + `sudo systemctl
reload caddy`. Removing a project = delete the file + reload.

### 3.6 Apex landing page

`jinx.generalproducts.io` itself serves a static `index.html` listing the
hosted projects. No auth, no dynamic content. Lives at `/srv/_apex/index.html`,
served by Caddy via:

```
jinx.generalproducts.io {
    tls /etc/ssl/jinx/cert.pem /etc/ssl/jinx/key.pem
    root * /srv/_apex
    file_server
}
```

### 3.7 Process supervision: systemd

Each long-running per-project process is a systemd unit named
`<project>-<role>.service` (e.g. `mim-web.service`, `mim-api.service`). Units
live at `/etc/systemd/system/`, owned by the project's deploy artifacts. Each
binds to `127.0.0.1:<port>` per the port-allocation table (§3.9).

Deploy automation restarts units via:

```
andrew ALL=(root) NOPASSWD: /usr/bin/systemctl restart <unit-list>
```

in `/etc/sudoers.d/<project>`. One sudoers file per project.

### 3.8 Per-project release-dir layout

Borrowed from `clipper.speedero.com` and generalized:

```
/srv/
  _apex/
    index.html
  <project>/
    current -> releases/<ts>           # symlink, atomic flip on deploy
    releases/
      <ts>/                            # one dir per deploy; prune to 5 newest
    shared/
      .env.production                  # secrets, symlinked into each release
      data/                            # uploads, sqlite, etc.
      postgres/                        # only if project runs its own Postgres
```

`/srv` chosen over Clipper's `/data` because FHS reserves `/srv` for "data
served by the system." `/data` was a Clipper-local convention.

Deploy script per project (modeled on Clipper's `scripts/deploy/deploy.sh`):

1. `git archive <ref>` streamed to `/srv/<project>/releases/<ts>/`
2. Build in the new release dir; old release keeps serving
3. Symlink `current` to the new release atomically (`ln -sfn` + `mv -Tf`)
4. `sudo -n systemctl restart <project>-*` (passwordless via sudoers)
5. Prune oldest releases, keep 5 newest

If the build fails, the symlink is not flipped and the old release keeps
serving. The failed release dir stays for debugging.

### 3.9 Port allocation

Manual table in `PORTS.md` at the root of the Jinx repo. Convention:

| Project    | Role | Port  |
| ---------- | ---- | ----- |
| mim        | web  | 3001  |
| mim        | api  | 3101  |
| poke-view  | web  | 3002  |

`web` ports start at 3001. `api` ports start at 3101. Worker/queue ports start
at 3201. Manual coordination is acceptable at scratch-tier scale; if the table
ever exceeds ~20 entries, revisit.

## 4. User and SSH

Single Linux user `andrew`, member of `sudo` group, default shell `bash`.

### 4.1 SSH keys

Pulled from `https://github.com/andrewmcadoo.keys` at provision time, written
to `/home/andrew/.ssh/authorized_keys` (mode `0600`, owner `andrew:andrew`).
Re-pull on demand via a small script (`/usr/local/bin/refresh-ssh-keys`) when
GitHub keys change.

### 4.2 sshd hardening

`/etc/ssh/sshd_config.d/90-jinx.conf`:

```
PasswordAuthentication no
PermitRootLogin no
AuthenticationMethods publickey
ChallengeResponseAuthentication no
KbdInteractiveAuthentication no
```

Restart `sshd` after install. Verify with
`ssh -o PreferredAuthentications=password andrew@jinx.generalproducts.io`
(must fail).

### 4.3 sudo

`/etc/sudoers.d/00-andrew`:

```
andrew ALL=(ALL) ALL
```

Full interactive sudo, prompts for password (same posture as a fresh Ubuntu
install — `andrew` was created in the `sudo` group, this just makes the
sudoers entry explicit and survives group changes).

Per-project NOPASSWD entries are added during project bootstrap, e.g.
`/etc/sudoers.d/mim`:

```
andrew ALL=(root) NOPASSWD: /usr/bin/systemctl restart mim-web mim-api
```

Each `/etc/sudoers.d/*` file installed via `visudo -cf` to validate syntax
before write.

### 4.4 SSH client config (AJ's laptop)

`~/.ssh/config`:

```
Host jinx
    Hostname jinx.generalproducts.io
    User andrew
    IdentityFile ~/.ssh/jinx_ed25519
    IdentitiesOnly yes
```

Identity file generated locally with
`ssh-keygen -t ed25519 -f ~/.ssh/jinx_ed25519 -C "aj@jinx"` and the public
half added to GitHub at https://github.com/settings/keys (so
`refresh-ssh-keys` picks it up).

## 5. Hardening

- **`ufw`** enabled, default deny inbound, allow `22/tcp` and `443/tcp`.
  Port 80 intentionally closed — see §3.2. Mirrors the Lightsail firewall;
  defense in depth.
- **`unattended-upgrades`** installed and enabled. Security patches applied
  nightly; reboot scheduled at 04:00 UTC if a kernel update requires it.
- **`fail2ban`** **not** installed. Justification: SSH is key-only (no
  password to brute-force), and HTTP/HTTPS is fronted by Cloudflare which
  absorbs scrapers and L7 floods. Fail2ban adds operational noise without
  meaningful gain at this tier.
- **No swap.** 2 GB RAM is enough for the planned workloads; if memory pressure
  appears, add a 2 GB swapfile rather than upsize the bundle.

## 6. Bootstrap and repo layout

A new git repo `~/Desktop/Workspace/jinx`, pushed to
`github.com/andrewmcadoo/jinx`. (If a `generalproducts` GitHub org is created
later, transfer the repo and update remotes; not blocking.) Contents:

```
jinx/
  README.md                              # what Jinx is, who it's for, link to runbook
  RUNBOOK.md                             # how to add a project, rotate certs, restore from snapshot
  PORTS.md                               # port allocation table (§3.9)
  bootstrap.sh                           # idempotent first-boot script (see §6.1)
  caddy/
    Caddyfile                            # base config that imports sites/
    sites/
      00-apex.caddy                      # apex landing page
      _example.caddy.tmpl                # template for new projects (non-matching ext)
  apex/
    index.html                           # static landing page (lists projects)
  systemd/
    _example.service                     # template for new project services
  sshd/
    90-jinx.conf                         # sshd_config.d drop-in
  scripts/
    refresh-ssh-keys.sh                  # re-pulls GitHub keys
  docs/
    superpowers/
      specs/
        2026-05-03-jinx-scratch-box-design.md   # this file
      plans/
        2026-05-03-jinx-scratch-box-plan.md      # implementation plan (next step)
  .github/
    workflows/
      lint.yml                           # shellcheck on bootstrap.sh, caddy validate on Caddyfile
  .gitignore
```

### 6.1 `bootstrap.sh`

Idempotent shell script, run once as the launch script (Lightsail user-data)
on first boot, re-runnable for recovery. Responsibilities:

1. `apt update && apt upgrade -y` (security patches)
2. Install: `caddy ufw unattended-upgrades curl ca-certificates`
3. Configure `ufw` (allow 22/443, default deny inbound, enable). **Not** 80
   — see §3.2.
4. Configure `unattended-upgrades`
5. Create `andrew` user, add to `sudo`, create `~/.ssh`
6. Pull SSH keys from `https://github.com/andrewmcadoo.keys` →
   `~andrew/.ssh/authorized_keys`
7. Install `/etc/ssh/sshd_config.d/90-jinx.conf`, restart `sshd`
8. Install `/etc/sudoers.d/00-andrew` (with `visudo -cf` check)
9. `mkdir -p /srv/_apex /etc/caddy/sites /etc/ssl/jinx /var/log/caddy`,
   `chown andrew:andrew /srv`
10. Drop in placeholder `/srv/_apex/index.html` ("Jinx is up. Projects will
    appear here.")
11. Print remaining manual steps (scp base `Caddyfile` and
    `sites/00-apex.caddy`, install Origin Cert at `/etc/ssl/jinx/`,
    enable+start caddy)

The script does **not** install the base `Caddyfile` or `sites/00-apex.caddy`.
Those land via `scp` from the operator's laptop after first SSH (see §6.2),
which keeps `bootstrap.sh` self-contained and avoids embedding repo content
in the cloud-init payload.

The script does **not** install the Origin Certificate. That happens manually
after launch (§7 step 5).

### 6.2 Launch procedure

1. **Create instance** in Lightsail console: region `us-east-1a`, blueprint
   `Ubuntu 24.04 LTS`, bundle `small_3_0`, name `jinx`, paste `bootstrap.sh`
   into the launch script field.
2. **Wait** ~3 minutes for cloud-init to complete. Tail:
   `aws lightsail get-instance-access-details --instance-name jinx`.
3. **Create static IP** named `jinx-static-ip`, attach to `jinx`.
4. **Cloudflare DNS**: add A record `jinx → <static-ip>` (proxied), CNAME
   `*.jinx → jinx.generalproducts.io` (proxied).
5. **Generate Origin Cert** in Cloudflare dashboard
   (SSL/TLS → Origin Server → Create Certificate; hostnames
   `jinx.generalproducts.io, *.jinx.generalproducts.io`; ECDSA; 15 years).
   Save cert + private key locally.
6. **`scp` cert and key** to Jinx:
   ```
   scp cert.pem andrew@jinx.generalproducts.io:/tmp/
   scp key.pem  andrew@jinx.generalproducts.io:/tmp/
   ssh jinx 'sudo install -m 0644 -o root -g caddy /tmp/cert.pem /etc/ssl/jinx/cert.pem
             sudo install -m 0640 -o root -g caddy /tmp/key.pem  /etc/ssl/jinx/key.pem
             rm /tmp/cert.pem /tmp/key.pem'
   ```
7. **Enable Caddy**:
   ```
   ssh jinx 'sudo systemctl enable --now caddy && sudo systemctl reload caddy'
   ```
8. **Smoke check**: `curl -I https://jinx.generalproducts.io` returns 200.
9. **Configure Cloudflare zone settings** for `generalproducts.io`:
   - SSL/TLS → Overview → mode: **Full (strict)**
   - SSL/TLS → Edge Certificates → **Always Use HTTPS: ON**
   - SSL/TLS → Edge Certificates → Minimum TLS Version: 1.2

   "Always Use HTTPS" is load-bearing — see §3.2 for why port 80 is closed at
   origin. Verify with `curl -I http://jinx.generalproducts.io` (must return
   301 → https).

Estimated wall-clock: 25 minutes.

## 7. Adding a project (the "deploy mim" template)

Each project follows this template. Detailed per-project plans (e.g. mim's)
live in their own beads issues and spec files.

1. **Allocate ports** in `PORTS.md`, commit to the Jinx repo.
2. **Write a `<project>.caddy`** site block, commit, `scp` to
   `/etc/caddy/sites/`, `sudo systemctl reload caddy`.
3. **Write systemd unit(s)** `<project>-<role>.service`, install at
   `/etc/systemd/system/`, `sudo systemctl daemon-reload`.
4. **Add NOPASSWD sudoers** at `/etc/sudoers.d/<project>` with the systemctl
   restart line for the project's units.
5. **Create `/srv/<project>/{releases,shared}`**, populate
   `shared/.env.production`.
6. **Add a `scripts/deploy/deploy.sh`** to the project repo, modeled on
   Clipper's. Run it once manually for the first deploy.
7. **(Optional)** Add `.github/workflows/deploy-<project>.yml` for
   merge-to-main auto-deploy. Defer until manual deploy is proven.

## 8. Out of scope (future tickets)

These are explicitly **not** part of standing up Jinx and become their own
beads issues after Jinx is live:

- **Deploy mim to Jinx.** Includes: build mim's frontend + FastAPI + Postgres-
  with-pgvector on the box, port assignments, env config, systemd units, Caddy
  site block, mim-specific `deploy.sh`. Substantial work; separate spec/plan.
- **CI/CD for the first project.** Modeled on Clipper's `deploy-clipper.yml`.
- **Cloudflare Tunnel migration.** Replace open `:22/:80/:443` with a tunnel.
  Reduces inbound surface to zero. Worth it once team grows beyond 1.
- **Per-teammate Linux accounts.** Defer until a teammate exists.
- **Monitoring beyond `journalctl`.** Add only after something breaks twice.
- **mim's PRD §22 production stack** (ECS Fargate, RDS Multi-AZ, SST). Locked
  unchanged. Jinx is the cheap-experiment tier; the PRD stack is the prod tier
  for projects that prove themselves.

## 9. Open questions

None blocking. The following are recorded as conscious deferrals:

- **Backup of `/srv/<project>/shared/`** beyond the daily Lightsail snapshot
  (e.g. `restic` to S3). Defer until a project lands data worth losing sleep
  over.
- **Per-project Postgres backup strategy.** Project-level concern, not Jinx-
  level. Each project that runs its own Postgres documents its own backup plan.

## 10. Decision log

Captured during the brainstorm that produced this spec. See conversation log
for full reasoning.

| Decision                           | Choice                              | Considered alternatives           |
| ---------------------------------- | ----------------------------------- | --------------------------------- |
| Cloud provider                     | AWS Lightsail                       | EC2 (overkill), Hetzner/DO (not AWS) |
| Region                             | `us-east-1a`                        | —                                 |
| OS                                 | Ubuntu 24.04 LTS                    | Debian, Amazon Linux              |
| Bundle                             | `small_3_0` ($10/mo, 2 GB RAM)      | nano (too small), medium (too much) |
| DNS                                | Cloudflare (registrar default)      | Lightsail DNS, Route 53           |
| Cloudflare proxy                   | ON (orange cloud)                   | Off (DNS-only)                    |
| TLS                                | Cloudflare Origin Cert (wildcard)   | Let's Encrypt via Caddy           |
| Cloudflare SSL mode                | Full (strict)                       | Flexible (insecure), Full         |
| Reverse proxy                      | Caddy                               | nginx, Traefik                    |
| Project routing                    | Subdomain-per-project               | Path-per-project                  |
| Process supervision                | systemd                             | Docker, supervisord, pm2          |
| Release layout                     | Clipper-shaped `releases/<ts>` + symlink | Single dir, Docker images        |
| Linux user model                   | Single user `andrew`                | Per-teammate users                |
| SSH access                         | Open `:22`, key-only, GitHub-keyed  | Cloudflare Tunnel + Access, Tailscale |
| Sudo posture                       | Full interactive + per-project NOPASSWD lines | NOPASSWD for everything       |
| `fail2ban`                         | Skip                                | Install                           |
| IaC                                | None — bootstrap shell + runbook    | Terraform, Pulumi, SST            |
| mim production stack on Jinx       | No (out of scope; PRD §22 unchanged) | Yes (would conflict with PRD)    |
