# ADR 0003: Self-hosting and Docker

## Status

Accepted.

## Context

The app is distributed as a Docker image for self-hosters. It needs to boot
with zero configuration (SQLite, no auth) while remaining configurable via
env vars for operators who want Postgres and/or OIDC login (see
[ADR 0001](0001-dual-database-adapter.md) and
[ADR 0002](0002-auth-and-sharing-model.md)).

## Decision

- **Build**: multi-stage `Dockerfile`, generated via `mix phx.gen.release
  --docker` and then customized. It compiles a `mix release` in a builder
  stage and copies only the release into a minimal final stage
  (`debian`-slim-based, matching the Erlang runtime's libc so NIFs like
  `exqlite` load correctly). `postgrex` is pure Elixir/`:ssl` and needs no
  native client library at runtime; `exqlite` (behind `ecto_sqlite3`)
  bundles/statically links its SQLite NIF, so no extra
  `apt-get install libsqlite3-...` should be required — this specific claim
  (image size, whether the runner stage's package list is sufficient) still
  needs confirming on a machine with Docker; everything else about the
  release/migration path has been verified without Docker itself (see below).
- **Data directory**: `VOLUME ["/data"]`, default
  `DATABASE_PATH=/data/debt_tracker.db` set via `ENV` in the final stage.
  Operators bind-mount a host directory to `/data` to persist the SQLite file
  outside the container.
- **Migrations on boot**: handled by the `Ecto.Migrator` child spec already in
  `DebtReliefTracker.Application.start/2` (from the phx.new sqlite3
  generator), gated on `RELEASE_NAME` being set — true inside any compiled
  release, false in `mix phx.server`/`mix test`. No separate migrate step is
  needed in the Docker `CMD`; `bin/server` alone is enough for
  `docker compose up` to produce a usable instance. (`bin/migrate` /
  `DebtReliefTracker.Release.migrate/0` still exist for manual/rollback use,
  e.g. `docker compose exec app bin/migrate`.)
- **`docker-compose.yml` + `docker-compose.postgres.yml`**: a primary file
  (SQLite-only: single service, single bind-mounted volume, no
  `DATABASE_URL`) plus a Postgres *overlay* file, composed via
  `docker compose -f docker-compose.yml -f docker-compose.postgres.yml up`
  — chosen over one file with commented-out sections since Compose's
  multi-file merge is exactly what an overlay like this is for, and it keeps
  the default (`docker compose up`) path free of Postgres-shaped noise.
- **`.env.example`**: documents every supported env var in one place —
  `SECRET_KEY_BASE`, `PORT`, `PHX_HOST`, `DATABASE_PATH`, `DATABASE_URL`
  (optional), `POOL_SIZE`, `POSTGRES_PASSWORD` (only used by the Postgres
  overlay), `OIDC_ISSUER` / `OIDC_CLIENT_ID` / `OIDC_CLIENT_SECRET`
  (optional, Phase 7).
- **`DebtReliefTracker.Release.migrate/0`**: the generated version iterates
  `Application.fetch_env!(:debt_relief_tracker, :ecto_repos)`, which lists
  *both* `Repo.Sqlite` and `Repo.Postgres` (so `mix ecto.gen.migration` etc.
  know about both) — migrating whichever one isn't active would fail to
  connect. Fixed to migrate only `DebtReliefTracker.Repo.configured_repo/0`,
  a small function (shared with `Application.start/2`) that reads the same
  `:ecto_adapter` config `config/runtime.exs` sets from `DATABASE_URL` vs.
  `DATABASE_PATH` — no `:persistent_term`/supervision-tree dependency, so it
  works standalone in a one-off `bin/migrate` invocation too.

## Consequences

- One image serves both deployment modes; operators choose via env vars
  alone, never a different image tag or rebuild.
- `SECRET_KEY_BASE` must be operator-supplied (or generated once and
  persisted) rather than baked into the image, since it's a real secret --
  `docker-compose.yml` fails fast (via Compose's `${VAR:?message}` syntax) if
  it's unset rather than silently booting insecurely.
- The release/migration path itself — `mix release`, `RELEASE_NAME`-gated
  auto-migration, first-run seeding, serving the dashboard — has been
  verified end-to-end locally (`MIX_ENV=prod mix release` +
  `bin/debt_relief_tracker start` against a fresh SQLite path). What remains
  unverified is Docker-specific: the actual image build, its size, and
  whether the runner stage's apt package list is sufficient — call this out
  explicitly rather than silently assuming it works, and treat it as a
  standing roadmap follow-up until confirmed on a machine with Docker.
