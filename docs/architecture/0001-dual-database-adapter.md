# ADR 0001: Dual database adapter (SQLite default, Postgres via env)

## Status

Accepted.

## Context

The app must be self-hostable with zero external dependencies out of the box
— a single Docker image that defaults to a SQLite file the operator can
bind-mount, e.g.:

```yaml
volumes:
  - ./data:/data
```

But it must also support Postgres for operators who already run a Postgres
instance and want to point the app at it, purely via environment variables
(`DATABASE_URL`) — without needing a different Docker image or a rebuild.

Ecto fixes a repo's adapter at **compile time**:

```elixir
defmodule MyApp.Repo do
  use Ecto.Repo, otp_app: :my_app, adapter: Ecto.Adapters.SQLite3
end
```

`use Ecto.Repo` generates the repo's callback functions based on the adapter
behaviour at compile time, so a single `Ecto.Repo` module cannot switch
adapters based on a runtime env var. This is the central constraint this ADR
works around.

## Decision

Ship **both** adapters in the same release/image, and pick which one is
active at boot:

1. Add both `{:ecto_sqlite3, "~> ..."}` and `{:postgrex, "~> ..."}` as deps.
2. Define two real `Ecto.Repo` modules:
   - `DebtReliefTracker.Repo.Sqlite` (adapter `Ecto.Adapters.SQLite3`)
   - `DebtReliefTracker.Repo.Postgres` (adapter `Ecto.Adapters.Postgres`)
3. Add a thin facade module, `DebtReliefTracker.Repo`, that is **not** an
   `Ecto.Repo` itself. It forwards the small set of functions the contexts
   actually call — `all/2`, `get/3`, `get!/3`, `get_by/3`, `one/2`, `insert/2`,
   `insert!/2`, `update/2`, `update!/2`, `delete/2`, `delete!/2`,
   `insert_all/3`, `update_all/3`, `delete_all/2`, `transaction/2`,
   `preload/3`, `aggregate/4`, `exists?/2` — to whichever repo module is
   currently active:

   ```elixir
   defmodule DebtReliefTracker.Repo do
     def all(queryable, opts \\ []), do: active_repo().all(queryable, opts)
     def get(queryable, id, opts \\ []), do: active_repo().get(queryable, id, opts)
     # ...

     def active_repo, do: :persistent_term.get({__MODULE__, :active_repo})
   end
   ```

4. `active_repo/0` is backed by `:persistent_term`, set exactly once during
   `Application.start/2` before the supervision tree starts. `persistent_term`
   is appropriate here specifically because the value is written once at boot
   and read (frequently) thereafter — it avoids either an ETS table or a
   `GenServer` round trip on every single query.
5. Activation logic (in `config/runtime.exs`, evaluated at boot for releases):
   - `DATABASE_URL` set → Postgres. Parse it into `Repo.Postgres`'s config.
   - Otherwise → SQLite, using `DATABASE_PATH` (default
     `/data/debt_tracker.db` in prod) as `Repo.Sqlite`'s `:database` option.
   - Dev/test use a `data/` directory at the repo root instead (kept out of
     git; see `.gitignore`) — `data/debt_relief_tracker_dev.db` and
     `data/debt_relief_tracker_test.db`, set directly in `config/dev.exs` /
     `config/test.exs` rather than through `DATABASE_PATH`, mirroring
     production's `/data` convention instead of scattering `.db` files at
     the repo root. `ecto_sqlite3`/`exqlite` creates the directory itself if
     it doesn't exist yet — no extra setup step needed.
6. `application.ex`'s supervision tree starts **only** the active repo's
   child process — not both — based on the same decision.
7. Migrations live in one shared `priv/repo/migrations/` directory, written
   adapter-portably: plain Ecto types only, no Postgres-only features (arrays,
   JSONB, etc.), so the same migration files apply cleanly to either adapter.
   Where a field needs structured data (e.g. `ActivityLog.metadata`), store it
   as a JSON-encoded text column rather than a Postgres-specific type.
8. Release boot runs pending migrations automatically (e.g. from the Docker
   entrypoint or a boot-time `Ecto.Migrator.run` call), so self-hosters never
   need to exec into the container to run a migration task by hand.

## Consequences

- Contexts and LiveViews only ever call `DebtReliefTracker.Repo.*` — they are
  written with no knowledge of which adapter is active.
- The facade must be kept in sync with whatever subset of `Ecto.Repo`'s API
  the app actually uses; it is not a full drop-in `Ecto.Repo` replacement
  (e.g. `Ecto.Repo.Sandbox` conveniences used in tests need is a Ecto Repo
  proper — tests are expected to run against `Repo.Sqlite` directly, or the
  facade needs a sandbox test shim; revisit when writing the test suite in
  Phase 4).
- Both `ecto_sqlite3`/`exqlite` and `postgrex` are compiled into every release,
  slightly increasing image size and compile time versus a single-adapter
  app — acceptable given the goal is one image for both deployment modes.
- Migrations must avoid adapter-specific SQL/types for the life of the
  project; this is a standing constraint on every future migration, not a
  one-time cost.

## Testing on Postgres

Production (Render) most likely runs Postgres, so the suite must pass there
too, not just on SQLite. `scripts/pg_test.sh` makes that a one-liner:

    scripts/pg_test.sh                              # create db, migrate, mix test
    scripts/pg_test.sh test --include browser       # incl. real-Chromium tests
    scripts/pg_test.sh migrate-check                # up, rollback the reversible tail, up again
    scripts/pg_test.sh run mix run --no-start scripts/pg_boot_check.exs
                                                    # boot path + encrypted round-trips

It `initdb`s a throwaway cluster in a `mktemp` dir (127.0.0.1 only, port 54329
or `PG_TEST_PORT`, trust auth, `fsync=off`), exports `DATABASE_URL` and
`DATABASE_USE_SSL=false`, and always stops and deletes the cluster on exit
(trap). Binaries come from `/usr/lib/postgresql/*/bin` (override with
`PG_BIN`). It never touches any other database. For ad hoc use, set
`DATABASE_URL` yourself and run plain `mix test`: setting it in `:test`
selects `Repo.Postgres` with the Sandbox pool (`config/runtime.exs`), and the
`test` alias, `DataCase` and `test_helper.exs` follow via
`Repo.configured_repo/0`. Without `DATABASE_URL`, `mix test` is unchanged
(SQLite). `DATABASE_USE_SSL` is now `false`/`0` to disable; anything else
(including unset) keeps SSL on.

Findings from the first full Postgres run:

- All migrations run forward on an empty database. Everything after
  `20260920130200` (`DropPlaintextColumns`) rolls back and re-applies;
  `DropPlaintextColumns` itself is irreversible by design (raises on `down`,
  same on SQLite), so `rollback --all` stops there.
- Column types (`information_schema`): ids are native `uuid`; every
  `Encrypted.*` field (`*_enc`) is `bytea` (SQLite: BLOB); `users.preferences`
  and `sent_emails.metadata` are `jsonb` (SQLite: JSON text).
- **Known defect, needs a new migration:** the migrations use plain
  `timestamps()` (`:naive_datetime`), which Postgres creates as
  `timestamp(0)` -- whole seconds. `ActivityLog.Entry` declares
  `:utc_datetime_usec` and its comments claim Postgres stores microseconds
  anyway; that is false for `activity_logs.inserted_at` (only `api_tokens`
  and `support_emails` were created with usec precision). On Postgres,
  activity entries from the same second order by random UUID in
  `ActivityLog.list_recent/2`. Fix: a migration altering
  `activity_logs.inserted_at` to `timestamp(6)` (not done here by design).
  Tests that assert "most recent first" call `backdate_activity/2`
  (`DataCase`) to be deterministic on both adapters.
- Raw SQL in tests must use `$1` placeholders and `Ecto.UUID.dump!/1` ids on
  Postgres (see `vault_test.exs`).
