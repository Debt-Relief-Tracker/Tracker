#!/usr/bin/env bash
# Runs migrations + the test suite against a THROWAWAY local Postgres cluster.
# See docs/architecture/0001-dual-database-adapter.md ("Testing on Postgres").
#
#   scripts/pg_test.sh                      # create db, migrate, mix test
#   scripts/pg_test.sh test --include browser
#   scripts/pg_test.sh migrate-check        # migrate up, rollback --all, migrate up
#   scripts/pg_test.sh run <cmd...>         # run any command with DATABASE_URL set (db created and migrated)
#
# The cluster lives in a fresh mktemp dir, listens on 127.0.0.1 only (trust
# auth, non-default port), and is stopped and deleted on exit. It never
# touches any other database.
set -euo pipefail

cd "$(dirname "$0")/.."

PG_BIN="${PG_BIN:-$(ls -d /usr/lib/postgresql/*/bin 2>/dev/null | sort -V | tail -1)}"
PORT="${PG_TEST_PORT:-54329}"
[ -x "$PG_BIN/initdb" ] || { echo "initdb not found; set PG_BIN" >&2; exit 1; }

BASE="$(mktemp -d "${TMPDIR:-/tmp}/pg_test.XXXXXX")"
DATA="$BASE/data"

cleanup() {
  "$PG_BIN/pg_ctl" -D "$DATA" -m immediate stop >/dev/null 2>&1 || true
  rm -rf "$BASE"
}
trap cleanup EXIT INT TERM

"$PG_BIN/initdb" -D "$DATA" -U postgres --auth=trust --encoding=UTF8 --locale=C.UTF-8 >/dev/null
"$PG_BIN/pg_ctl" -D "$DATA" -w -l "$BASE/pg.log" \
  -o "-c listen_addresses=127.0.0.1 -p $PORT -c unix_socket_directories=$BASE -c fsync=off" start >/dev/null

export DATABASE_URL="ecto://postgres@127.0.0.1:$PORT/debt_relief_pg_test"
export DATABASE_USE_SSL=false
# Never inherit a SQLite path override.
unset DATABASE_PATH || true
export MIX_ENV=test

cmd="${1:-test}"
[ $# -gt 0 ] && shift

case "$cmd" in
  test)
    mix ecto.create -r DebtReliefTracker.Repo.Postgres
    mix ecto.migrate -r DebtReliefTracker.Repo.Postgres
    mix test "$@"
    ;;
  migrate-check)
    mix ecto.create -r DebtReliefTracker.Repo.Postgres
    mix ecto.migrate -r DebtReliefTracker.Repo.Postgres
    # DropPlaintextColumns (20260920130200) is irreversible by design, so roll
    # back only the reversible tail after it.
    mix ecto.rollback --to 20260920140000 -r DebtReliefTracker.Repo.Postgres
    mix ecto.migrate -r DebtReliefTracker.Repo.Postgres
    mix ecto.migrations -r DebtReliefTracker.Repo.Postgres | tail -5
    ;;
  run)
    mix ecto.create -r DebtReliefTracker.Repo.Postgres
    mix ecto.migrate -r DebtReliefTracker.Repo.Postgres
    "$@"
    ;;
  *)
    echo "unknown command: $cmd" >&2
    exit 2
    ;;
esac
