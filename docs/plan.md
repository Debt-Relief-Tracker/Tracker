# Debt Relief Tracker — Build Plan

This is the living build plan for the Elixir/Phoenix implementation of the
feature set in [`../minimum.md`](../minimum.md). It is kept up to date as work
lands; see [`roadmap.md`](roadmap.md) for the phase-by-phase checklist and
[`architecture/`](architecture/) for the ADRs behind the non-obvious design
decisions.

## Requirements beyond the feature list

1. **Self-hosted, SQLite-first** — defaults to a SQLite file the operator can
   bind-mount via Docker, but must support Postgres via env vars, as a single
   Docker image that is runtime-switchable (not two separate builds). See
   [`architecture/0001-dual-database-adapter.md`](architecture/0001-dual-database-adapter.md).
2. **Auth & sharing, Actual-Budget-style** — no login by default (single
   implicit user/workspace). Optionally wire up an external OIDC provider, at
   which point data becomes genuinely per-user (each user owns their own set
   of debts) but shareable — an owner can grant another logged-in user access
   to their workspace. See
   [`architecture/0002-auth-and-sharing-model.md`](architecture/0002-auth-and-sharing-model.md).
3. **Self-hosting / Docker** — see
   [`architecture/0003-self-hosting-and-docker.md`](architecture/0003-self-hosting-and-docker.md).
4. **Everything planned or decided is committed as markdown** — this plan, the
   roadmap, and the ADRs, kept current in the repo rather than living only in
   chat history.

## Phases

### Phase 1 — Bootstrap the Phoenix app

Generate in place with
`mix phx.new . --app debt_relief_tracker --module DebtReliefTracker --database sqlite3 --adapter bandit`.
Starting from the sqlite3 generator gives correct `ecto_sqlite3`
wiring/migration conventions; Postgres support is added manually in Phase 2 —
retrofitting sqlite onto a Postgres-generated app is more work the other way
around. Keep LiveView, Tailwind, esbuild, gettext, and mailer generators on
(defaults).

### Phase 2 — Dual database adapter (SQLite default, Postgres via env)

See [ADR 0001](architecture/0001-dual-database-adapter.md) for the full
design. Summary: two real `Ecto.Repo`s (`Repo.Sqlite`, `Repo.Postgres`) are
compiled into the same release, and a thin non-Ecto `Repo` facade forwards
calls to whichever one is activated at boot based on `DATABASE_URL` (Postgres)
vs. `DATABASE_PATH` (SQLite, the default).

### Phase 3 — Core domain & first-run seed data

Data is scoped per **workspace** (not one global table), so it can support
real ownership + sharing without a later schema migration:

- `Accounts`: `User`, `Workspace`, `WorkspaceMember` (join table with role).
- `Debts`: `Debt` schema scoped by `workspace_id`, with `status`/`paid_off_at`
  for the explicit "mark as paid" action.
- `Payments`: `Payment` schema tied to a debt, with optional
  `logged_by_user_id` for attribution.
- `Settings`: one row per workspace.
- `ActivityLog`: every mutating action (`debt_added`, `debt_updated`,
  `debt_paid_off`, `payment_logged`) is recorded via a single
  `ActivityLog.record/5` helper called from inside the relevant context
  function, so logging can't be skipped at the call site.
- First-run placeholder debts seeded at boot for the default workspace only
  (from `minimum.md`'s intro note), not via `priv/repo/seeds.exs` (which
  doesn't run automatically for self-hosters).

### Phase 4 — Calculation engine (pure, heavily unit-tested)

- `DebtReliefTracker.Debts.Calculations` — dynamic minimum payment
  (`max(floor, rate × balance)` for revolving, fixed for installment),
  interest accrual estimate/reconciliation, lifetime interest paid/saved.
- `DebtReliefTracker.Planning` — cash flow / snowball / avalanche orderings,
  month-by-month simulation, "this month" action, windfall allocator.
  Pure functions over plain structs, independent of Ecto/LiveView, so they're
  cheap to unit test exhaustively.

### Phase 5 — LiveView UI

One primary interface: a single `DashboardLive` LiveView laid out as a
persistent narrow left rail (~1/5 width, simplified debt list + add/edit/mark
paid/log payment actions) plus a large main panel (graph-first: a chart-type
switcher across strategy comparison, month-by-month simulation, cash-flow-freed
chart, and interest/principal breakdown). No separate CRUD pages — modals/slide
overs instead. Charts are real Chart.js charts rendered via a `PlanChart` JS
hook, fed by `DebtReliefTrackerWeb.Charts` config-building — see
[ADR 0004](architecture/0004-charting-library.md) (this superseded an initial
hand-rolled-SVG approach once richer charts were needed).

### Phase 6 — Self-hosting / Docker

See [ADR 0003](architecture/0003-self-hosting-and-docker.md). Multi-stage
`Dockerfile` producing a `mix release`, `VOLUME /data`, default
`DATABASE_PATH=/data/debt_tracker.db`, `docker-compose.yml` with SQLite-only
and Postgres examples, `.env.example` documenting every supported env var.

### Phase 7 — Optional OIDC auth & sharing

See [ADR 0002](architecture/0002-auth-and-sharing-model.md). No OIDC env vars
→ no login wall, single implicit workspace. OIDC configured (via `assent`) →
real login, each user gets their own workspace, and an owner can share it with
another logged-in user via `WorkspaceMember`.

## Verification

- `mix test` for the calculation engine — highest-value area for unit tests
  (payoff math correctness).
- `mix phx.server` locally against the default SQLite path; manually exercise
  creating a debt, logging a payment, viewing the strategy comparison,
  toggling theme.
- Re-run against `DATABASE_URL` pointed at a local Postgres to confirm the
  runtime adapter switch actually activates Postgres.
- Docker image build/run should be tested on a machine with Docker installed
  (not available in the original planning environment).
