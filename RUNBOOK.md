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
   cp caddy/sites/_example.caddy.tmpl caddy/sites/<project>.caddy
   # Edit hostname, ports, log filename.
   ```
   The `.tmpl` suffix on the template means it cannot match the
   `sites/*.caddy` import glob even if it's accidentally scp'd to
   `/etc/caddy/sites/` — defense against typos.
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
             /tmp/<project>.caddy /etc/caddy/sites/<project>.caddy \
             && sudo install -m 0644 -o caddy -g caddy /dev/null \
             /var/log/caddy/<project>.log \
             && sudo systemctl restart caddy \
             && rm /tmp/<project>.caddy'
   ```
   The `install … /dev/null /var/log/caddy/<project>.log` line
   pre-creates the per-site log file with caddy ownership. Without
   this, Caddy can't `open()` the missing file the first time it
   tries to log a request — and even if it auto-created one, the apt
   postinst race owns it `root:root` mode `0600` so caddy can't write
   to it (mim-lp4 / nabu-jaau). Snapshot-restore
   re-runs of `bootstrap.sh` auto-discover existing sites and
   pre-create any missing log files (`bootstrap.sh` →
   `configure_filesystem()`).
7. **Install the systemd unit(s):**
   ```
   scp systemd/<project>-<role>.service jinx:/tmp/
   ssh jinx 'sudo install -m 0644 -o root -g root \
             /tmp/<project>-<role>.service /etc/systemd/system/ \
             && sudo systemctl daemon-reload \
             && rm /tmp/<project>-<role>.service'
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
12. **Update `apex/index.html`** to list the new project; redeploy:
    ```
    scp apex/index.html jinx:/srv/_apex/index.html
    ```
    `/srv/_apex` is owned by `andrew:andrew` (bootstrap.sh §6.1 step 9), so
    no sudo / `install` dance is needed for the apex page — direct `scp`
    overwrites the placeholder in place.

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
   ssh jinx 'sudo install -m 0644 -o root -g caddy /tmp/cert.pem /etc/ssl/jinx/cert.pem \
             && sudo install -m 0640 -o root -g caddy /tmp/key.pem  /etc/ssl/jinx/key.pem \
             && rm /tmp/cert.pem /tmp/key.pem \
             && sudo systemctl restart caddy'
   ```
5. Verify the **origin** cert (not the Cloudflare edge cert).
   `curl https://jinx.generalproducts.io` resolves to a Cloudflare edge IP
   and inspects CF's edge cert — that won't tell you anything about the cert
   you just installed on the box. Use `--resolve` to force curl to bypass
   Cloudflare and hit the Lightsail static IP directly while still sending
   SNI for `jinx.generalproducts.io`:
   ```
   ORIGIN_IP=<jinx static IP from Lightsail console>
   curl -vk --resolve "jinx.generalproducts.io:443:${ORIGIN_IP}" \
        https://jinx.generalproducts.io 2>&1 \
     | grep -E "subject:|issuer:|expire"
   ```
   Expect `issuer: CN=Cloudflare Origin Certificate Authority` and an expiry
   matching the cert you just generated. A Cloudflare edge cert (e.g.
   `issuer: ...Google Trust Services...`) means you didn't bypass CF — fix
   the resolve target. `-k` is intentional: the origin cert isn't in any
   public trust store, so curl would otherwise fail to verify it.

## Refreshing SSH keys

When you add or remove a key on https://github.com/settings/keys:

```
ssh jinx 'sudo /usr/local/bin/refresh-ssh-keys'
```

## Restoring from a Lightsail snapshot

1. Lightsail console → Snapshots → pick most recent → "Create new instance from snapshot".
2. Use bundle `small_3_0`, name `jinx-restored`.
3. Detach the static IP from the old `jinx`, attach to `jinx-restored`.
   **Expect 30s–2min of Cloudflare 521/522 errors** during this window —
   the static IP is briefly unattached, so CF can't reach origin.
   Tolerable for a scratch box; mention in any user-visible status post.
4. Cloudflare DNS auto-resolves on next TTL (no change needed if static IP is reused).
5. SSH to verify, then delete the old instance.

## Emergency: locked out of SSH

If a sudoers/sshd change locks you out:

1. Lightsail console → Connect → "Connect using SSH" (browser-based).
   Lightsail injects its own short-lived public key into the instance's
   authorized_keys via the Lightsail agent and then connects with the
   matching private key — so it still goes through sshd and respects
   `PasswordAuthentication no` / `AuthenticationMethods publickey`. What it
   bypasses is *your* SSH key chain, not your sshd hardening.
   **Important:** sshd has `AllowUsers andrew` set, so the default Lightsail
   Connect username (`ubuntu`) will be refused. In the Connect dialog,
   override the username to `andrew` before clicking connect.
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
| Caddy apply config changes        | `sudo systemctl restart caddy` (see note below) |

**Why `restart`, not `reload`:** the global Caddyfile sets `admin off`,
which disables the localhost:2019 admin API. Caddy's `ExecReload=` runs
`caddy reload --config …` which POSTs to that admin socket and exits
non-zero when the socket isn't there. Use `systemctl restart caddy` for
all config changes — brief (sub-second) outage, acceptable for jinx.
Documented at `caddy/Caddyfile` (nabu-09jr).
