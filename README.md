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
