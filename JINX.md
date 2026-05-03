# JINX.md — deploying this project to Jinx

> **For AI agents and humans:** This project deploys to **Jinx**, a shared scratch
> deployment box at `jinx.generalproducts.io`. Read this file before changing
> anything that touches `scripts/deploy/`, `.env.production`, or anything served
> from the public URL.
>
> **Canonical reference:** [`github.com/andrewmcadoo/jinx`](https://github.com/andrewmcadoo/jinx) — Jinx repo with `RUNBOOK.md`, `PORTS.md`, `bootstrap.sh`, and per-project Caddy/systemd templates.
>
> **This file is a template.** Replace every `<…>` placeholder with this project's actual values, then commit. The `## This project on Jinx` section is the only place project-specific facts live.

---

## The contract

| | |
|---|---|
| **Public URL** | `https://<project>.jinx.generalproducts.io` |
| **SSH** | `ssh jinx` (alias in `~/.ssh/config`) → user `andrew` on the box |
| **Deploy** | `./scripts/deploy/deploy.sh` from this repo |
| **Tier** | **scratch** — explicitly NOT production. If this project earns a real prod target, it migrates off Jinx. |
| **Provider** | AWS Lightsail, `us-east-1`, `23.23.181.232`, fronted by Cloudflare (proxy on, Origin Cert wildcard, Full-strict TLS). |

---

## This project on Jinx — FILL IN

> Replace this whole block with concrete values when adopting JINX.md into a new project.

| Field | Value |
|---|---|
| **Project slug** | `<project>` (e.g. `mim`) |
| **Subdomain** | `<project>.jinx.generalproducts.io` |
| **Services (systemd unit per row)** | `<project>-web` on `127.0.0.1:<webport>` · `<project>-api` on `127.0.0.1:<apiport>` · *(add more as needed)* |
| **DB on box?** | yes / no — if yes, port + version (e.g. Postgres 15 + pgvector on `127.0.0.1:<dbport>`) |
| **Env file** | `/srv/<project>/shared/.env.production` (NOT in this repo — see "Secrets" below) |
| **Logs (Caddy)** | `/var/log/caddy/<project>.log` |
| **Logs (services)** | `journalctl -u <project>-<role>` |
| **Ports owned** | as recorded in [`jinx/PORTS.md`](https://github.com/andrewmcadoo/jinx/blob/main/PORTS.md) |

---

## Where files live

| Concern | Location | Repo |
|---|---|---|
| App source code | this repo | this repo |
| Deploy script | `scripts/deploy/deploy.sh` | this repo |
| `.env.production` | `/srv/<project>/shared/.env.production` on the box | **never committed** anywhere |
| Caddy site block | `/etc/caddy/sites/<project>.caddy` (deployed from `caddy/sites/<project>.caddy` in jinx repo) | **jinx repo** |
| systemd unit(s) | `/etc/systemd/system/<project>-<role>.service` (deployed from `systemd/<project>-<role>.service` in jinx repo) | **jinx repo** |
| sudoers NOPASSWD line | `/etc/sudoers.d/<project>` on the box | jinx repo (or set by hand once) |
| Port allocation | `PORTS.md` row | **jinx repo** |
| Cloudflare DNS / cert | Cloudflare dashboard | not in any repo |

**Rule of thumb:** if the artifact is *one-per-project* and *deployed from a config file*, it lives in the **jinx repo**. If it's app code or app-specific deploy plumbing, it lives **here**.

---

## SSH

```bash
ssh jinx                     # alias: andrew@jinx.generalproducts.io
ssh jinx 'sudo systemctl status <project>-<role>'
```

If `ssh jinx` fails: see Jinx repo `RUNBOOK.md` § SSH and § "Refreshing SSH keys."

---

## Deploy

The deploy script in this repo (modeled on Clipper's pattern: `git archive` → release dir → atomic symlink swap → service restart) does:

1. `git archive <ref>` streamed via SSH to `/srv/<project>/releases/<ts>/`
2. Build in the new release dir (the old release keeps serving)
3. Symlink `current` to the new dir atomically (`ln -sfn` + `mv -Tf`)
4. `sudo -n systemctl restart <project>-<role>` (passwordless via `/etc/sudoers.d/<project>`)
5. Prune oldest releases (keep 5)

```bash
./scripts/deploy/deploy.sh                # deploys default ref
./scripts/deploy/deploy.sh <ref>          # deploys a specific ref
```

A failed build does **not** flip the symlink — the old release keeps serving; the failed dir stays for inspection at `/srv/<project>/releases/<ts>/`.

GitHub Actions equivalent (preferred for merged-to-main): `.github/workflows/deploy.yml` — see the Clipper template at `speedero-security/.github/workflows/deploy-clipper.yml` for the SSH-key + tarball-upload pattern.

---

## Common operations

```bash
# Tail combined Caddy log
ssh jinx 'sudo tail -f /var/log/caddy/<project>.log'

# Tail a specific service
ssh jinx 'sudo journalctl -u <project>-<role> -f'

# Restart a service (without redeploying)
ssh jinx 'sudo systemctl restart <project>-<role>'

# Service status + recent logs
ssh jinx 'sudo systemctl status <project>-<role>'

# Roll back to the previous release
ssh jinx '
  cd /srv/<project>/releases
  prev=$(ls -1t | sed -n 2p)
  sudo -u andrew ln -sfn /srv/<project>/releases/$prev /srv/<project>/current.new
  sudo -u andrew mv -Tf /srv/<project>/current.new /srv/<project>/current
  sudo systemctl restart <project>-<role>
'

# Disk usage by project
ssh jinx 'sudo du -sh /srv/*'
```

---

## Secrets

**Never commit secrets.** This repo's `.gitignore` MUST cover at minimum:

```
.env
.env.*
!.env.example
*.pem
*.key
*.crt
```

Production secrets live in `/srv/<project>/shared/.env.production` on the box, populated **once** during project bootstrap by SSHing in and writing the file (or via a one-shot scp + install). The deploy script symlinks it into each release.

Rotate by:

```bash
ssh jinx '
  sudo nano /srv/<project>/shared/.env.production       # or sed -i for automation
  sudo systemctl restart <project>-web <project>-api
'
```

---

## When this project changes its Jinx surface

If this project changes any of the following, edits are needed in the **jinx repo** (`github.com/andrewmcadoo/jinx`), not here:

- New port allocation → edit `PORTS.md`
- Caddy routing changes (new path, header, etc.) → edit `caddy/sites/<project>.caddy`
- New service / changed `ExecStart` / new env var → edit `systemd/<project>-<role>.service`
- New systemd unit needing automated restart → add line to `/etc/sudoers.d/<project>` on the box (and document in jinx repo if reproducible)

After committing in the jinx repo, scp the changed file to the box and reload (per jinx `RUNBOOK.md` → "Adding a project" steps 6–7).

---

## Adding this project to apex listing

`https://jinx.generalproducts.io` serves a static index (`/srv/_apex/index.html`) listing live projects. After this project is up, add an `<li>` to `apex/index.html` in the jinx repo, commit, and `scp` to `/srv/_apex/index.html`. (No `sudo install` needed — `/srv/_apex` is `andrew`-owned.)

---

## Don't

- ❌ Don't commit `.env.production`, `*.pem`, `*.key`, `*.crt`. The Jinx repo's `.gitignore` covers these defensively; this project's `.gitignore` should too.
- ❌ Don't `git add .` — add files individually (per global agent rules; `.env` files have been committed by accident this way).
- ❌ Don't edit `/srv/<project>/current/...` directly on the box — those are release-dir contents, overwritten on next deploy.
- ❌ Don't `apt-get install` ad-hoc on the box. If a new package is needed, add it to `bootstrap.sh` in the jinx repo so snapshot restores reproduce the state.
- ❌ Don't expose new ports on `0.0.0.0`. All processes listen on `127.0.0.1` only — Caddy is the only public surface.
- ❌ Don't issue Let's Encrypt certs. TLS is handled by Cloudflare Origin Cert (wildcard, 15-year, installed once at `/etc/ssl/jinx/`).
- ❌ Don't `systemctl enable --now` a fresh service before its first deploy — the unit's `WorkingDirectory=/srv/<project>/current` won't resolve until `deploy.sh` runs once.
- ❌ Don't store production-grade data here. Backups are limited to Jinx's daily snapshot (7-day retention). If losing a week of state would matter, this project belongs off Jinx.

---

## When this project graduates off Jinx

Jinx is the cheap-experiment tier. If this project earns a real production target:

1. Stand up the project's prod stack (per its own infra spec — for `mim`, that's `IMPLEMENTATION_PLAN.md` + `docs/PRD.md` §22, ECS Fargate + RDS Multi-AZ).
2. Move DNS to the prod target's hostname.
3. Drain Jinx: stop the systemd units, archive `/srv/<project>/shared/`, remove the Caddy site block, `bd close` any Jinx-specific issues.
4. Update this `JINX.md` to reflect that the project is no longer on Jinx (or delete it).

---

## Canonical Jinx docs (always check the source)

- [`github.com/andrewmcadoo/jinx`](https://github.com/andrewmcadoo/jinx) — Jinx repo
  - `RUNBOOK.md` — full operational procedures (cert rotation, snapshot restore, lockout recovery, "Adding a project" walkthrough)
  - `PORTS.md` — port allocation table (edit here when allocating a new port)
  - `docs/superpowers/specs/2026-05-03-jinx-scratch-box-design.md` — design spec (architecture, why the choices)
  - `bootstrap.sh` — first-boot configuration of the box

If anything in this `JINX.md` contradicts the canonical Jinx repo, **the Jinx repo wins** — open a PR to update this file.
