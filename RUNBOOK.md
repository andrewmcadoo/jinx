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
