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

`Status` values: `reserved` | `active` | `paused` | `retired`.

## Allocations

| Project   | Role   | Port | Status   | Notes                  |
| --------- | ------ | ---- | -------- | ---------------------- |
| _example_ | _web_  | 3099 | reserved | Template; never bound. Sentinel out of normal allocation flow — avoids collision with the Next.js dev-server default of `:3000`. |
| mimir     | web    | 3001 | active   | Next.js 16 SSR frontend. Caddy default `handle` → this port. First deploy 2026-05-12. |
| mimir     | api    | 3199 | active   | FastAPI/uvicorn backend. Caddy `handle_path /api/*` strips `/api` and forwards here (api mounts routers at root — `apps/api/src/app/main.py:38-40`). Top-of-31xx by deliberate choice — leaves 3101-3198 open for future projects. First deploy 2026-05-12. |
