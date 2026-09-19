# Roadmap

Checklist tracking [`plan.md`](plan.md). Check items off as they land; add
new sub-items as work is discovered, but keep phase numbers/titles stable so
this stays a stable reference from commit messages and PRs.

## Documentation

- [x] `docs/plan.md`
- [x] `docs/roadmap.md` (this file)
- [x] `docs/architecture/0001-dual-database-adapter.md`
- [x] `docs/architecture/0002-auth-and-sharing-model.md`
- [x] `docs/architecture/0003-self-hosting-and-docker.md`
- [x] `docs/architecture/0004-charting-library.md`

## Phase 1 — Bootstrap the Phoenix app

- [x] `mix phx.new` in place (sqlite3, bandit)
- [x] `.gitignore` covers `_build/`, `deps/`, `node_modules/`, `*.db*`, `.env`
- [x] `.env.example` scaffolded (filled in as later phases add vars)
- [x] Dev/test SQLite files live in a `data/` directory at the repo root
      (`data/debt_relief_tracker_dev.db`, `data/debt_relief_tracker_test.db`)
      rather than scattered at the repo root, mirroring production's `/data`
      convention. `ecto_sqlite3`/`exqlite` creates the directory itself.

## Phase 2 — Dual database adapter

- [x] `ecto_sqlite3` + `postgrex` deps added
- [x] `Repo.Sqlite` / `Repo.Postgres` real repos defined
- [x] `Repo` facade module forwarding to the active repo
- [x] `config/runtime.exs` activation logic (`DATABASE_URL` vs `DATABASE_PATH`)
- [x] `application.ex` starts only the active repo's child
- [x] Migrations run automatically on release boot (verified in Phase 6, once
      a release/Dockerfile existed to check it against; `skip_migrations?/0`
      gates this on `RELEASE_NAME`)

Verified manually: `mix ecto.create -r DebtReliefTracker.Repo.Sqlite` creates
the dev db; `mix phx.server` boots and serves `/` (200) against SQLite by
default; setting `DATABASE_URL` switches `Repo.active_repo/0` to
`Repo.Postgres` (confirmed via `mix run -e`, connection itself refused since
no local Postgres is running in this environment — expected).

## Phase 3 — Core domain & first-run seed data

- [x] `Accounts` context: `User`, `Workspace`, `WorkspaceMember`
- [x] `Debts` context: `Debt` schema (+ `status`/`paid_off_at`)
- [x] `Payments` context: `Payment` schema
- [x] `Settings` context
- [x] `ActivityLog` schema + `record/5` helper wired into every mutation
- [x] First-run placeholder debts seeded for the default workspace

Verified: `DebtReliefTracker.Boot.run/0` (called from `Application.start/2`,
skipped in test via `:run_boot_tasks` config) creates the default user +
workspace + owner membership and seeds 3 placeholder debts (2 revolving, 1
installment), idempotently. Context tests cover create/update/mark-paid-off
debt validations, activity logging, and payment balance reduction +
overdraw rollback -- `mix test` passes (15 tests). Note: SQLite-backed tests
must NOT use `async: true` (`Database busy` errors from concurrent
sandboxed connections) -- this is called out in the generated `DataCase`
moduledoc and confirmed the hard way.

## Phase 4 — Calculation engine

- [x] `Debts.Calculations`: dynamic minimum payment, interest accrual/estimate,
      lifetime interest paid
- [x] `Planning`: cash flow / snowball / avalanche orderings
- [x] `Planning`: month-by-month simulation (fixed order, same-month cascade,
      `:insufficient_budget` / `:did_not_converge` guards)
- [x] `Planning`: "this month" action derivation (`this_month_action/3`)
- [x] `Planning`: windfall allocator (`windfall_cascade/4`)
- [x] `Planning`: freed-cashflow-over-time (`freed_cashflow_over_time/3`)
- [x] Unit tests for all of the above (20 tests, pure -- no DB)
- [x] "Financial health" section from minimum.md: credit utilization per card
      and overall, when credit limits are entered -- `Calculations.credit_utilization/1`
      (per-debt, revolving only) and `overall_credit_utilization/1` (aggregate,
      `nil` when no debt has a `credit_limit` set so the UI can hide it), surfaced
      as a badge in the rail and a 5th stat tile

Note: "interest saved vs. an interest-only baseline" from minimum.md is
covered indirectly via `windfall_cascade/4` (baseline vs. with-windfall) and
`compare_strategies/2` (strategy vs. strategy); a literal "pay interest-only
forever" baseline isn't modeled since it may never converge for revolving
debt. Revisit if Phase 5's financial-health section needs that literal
comparison.

## Phase 5 — LiveView UI

- [x] `DashboardLive` skeleton: left rail + main panel layout
- [x] Left rail: simplified debt list
- [x] Add/edit debt modal
- [x] Mark-as-paid action
- [x] Delete debt action (outright remove a debt from a workspace, distinct
      from marking it paid off -- `Debts.delete_debt/3`, cascades to the
      debt's payments, logs `:debt_deleted` with `debt: nil` since the FK
      would reject a log entry pointing at a just-deleted id)
- [x] Log payment modal + log-all-balances modal (bulk balance reconciliation
      via `Debts.reconcile_balance/5`, added during this phase)
- [x] Chart-type switcher + 4 chart types, upgraded to real Chart.js charts
      (see below): dual-axis bar (comparison), multi-line with a per-debt
      breakdown (simulation), filled area (freed cash flow), doughnut
      (interest vs. principal)
- [x] "This month" action card
- [x] Dark/light theme toggle -- this shipped for free: Phoenix 1.8's
      generator already wires up daisyUI light/dark themes + a
      `Layouts.theme_toggle/1` component + the `data-theme`/localStorage JS in
      `root.html.heex`. We just reuse it rather than building our own.

### Charting upgrade (Chart.js, post-initial-build)

The initial build used hand-rolled inline SVG (bars/polylines) to keep the
self-hosted JS footprint light, per the original plan. The user asked for
"more capable" charts with more information, which SVG-by-hand wasn't going
to deliver well, so this was revisited:

- [x] `chart.js` added as an `assets/package.json` dependency (npm, bundled
      by the existing esbuild pipeline -- no CDN, still fully self-hosted)
- [x] `assets/js/plan_chart_hook.js` -- a `PlanChart` LiveView hook. Server
      pushes a full Chart.js config via `push_event(socket, "plan-chart-data", config)`;
      the hook just does `new Chart(canvas, config)`, destroying/recreating
      the instance on every push rather than trying to patch across
      chart-type changes (bar → line → doughnut configs aren't compatible)
- [x] `DebtReliefTrackerWeb.Charts` -- a new, pure module building the
      Chart.js config map (or a `{message, nil}` fallback when there's
      nothing to plot yet) for each of the 4 chart types. No Ecto, no
      rendering; independently unit tested
- [x] Comparison is now a **dual-axis bar chart** (interest $ on the left
      axis, months to payoff on the right) instead of interest-only
- [x] Simulation now plots **one line per debt plus a dashed Total line**,
      instead of just the aggregate total -- directly answering "that's not
      enough info"
- [x] Interest-vs-principal is now a **doughnut** with a legend/tooltips,
      instead of a plain CSS stacked bar
- [x] The `<canvas id="plan-chart" phx-hook="PlanChart" phx-update="ignore">`
      element persists across chart-type switches (only removed from the DOM
      when there's a `@chart_message` fallback instead) -- the hook's
      `handleEvent` subscription survives, so switching chart types is just
      another `push_event`, not a hook remount
- [x] Found and fixed a real, pre-existing bug while testing this:
      `Payments.log_payment/4` computed a principal/interest split to adjust
      the debt's balance but never persisted that split onto the `Payment`
      row itself unless the caller explicitly supplied it -- so a payment
      logged via the simple "amount only" form (the common case) silently
      stored a `nil` `principal_portion`, zeroing it out of the
      interest-vs-principal chart and any other lifetime reporting. Fixed to
      always persist the computed value.
- [x] Chart colors are now theme-adaptive: the JS hook recolors client-side
      on `data-theme` changes (a `MutationObserver`, matching the server's
      `@palette` hex values by exact value, not position, then swapping in a
      brighter dark-mode counterpart per hue) and re-renders in place via the
      existing destroy/recreate path -- no new server push per theme toggle
- [x] All dollar amounts shown to the user are comma-grouped: `format_money/1`
      in `DashboardLive` (rail balances, "this month" card) does its own
      thousands-grouping (no comma-formatting library in Elixir core), and
      the `PlanChart` JS hook applies `Intl.NumberFormat` currency formatting
      to Chart.js axis ticks and tooltips client-side, since the data pushed
      to Chart.js has to stay raw numbers for plotting -- only the
      tick/tooltip *display* callbacks can add the `$`/commas, and those are
      JS functions that can't cross a `push_event` payload, so they're
      applied in the hook rather than computed server-side. Editable number
      inputs (monthly budget, log-all-balances) are deliberately left
      uncommaified -- commas break native `<input type="number">` values.
- Verified: `mix test` (66 tests, including `Charts` unit tests and a
  `DashboardLive` test asserting the actual pushed Chart.js config per chart
  type via `assert_push_event/3`), a real `mix phx.server` boot confirming
  the canvas + hook render and the bundled `app.js` actually contains
  Chart.js. The rendered chart's *visual* correctness (colors, layout,
  tooltip behavior in an actual browser) has not been eyeballed in a real
  browser in this environment -- worth a quick look before relying on it.

Deviations from the original plan, and why:
- Charts are implemented as **private function components inside
  `DashboardLive`** for layout, with the actual chart config-building
  extracted to `DebtReliefTrackerWeb.Charts` -- not a separate `PlanChart`
  live_component, per earlier "keep it simple" feedback; a plain hook +
  pure module needed no LiveComponent process/state.
- The default monthly budget (when unset) is the sum of eligible debts'
  minimum payments **+5%**, not a flat guess -- otherwise the plan starts in
  an "insufficient budget" error state for realistic debt loads (found by
  actually running the app against the seeded placeholder debts).
- Found and fixed a real bug while writing LiveView interaction tests:
  `Planning.simulate/4` checked budget feasibility once upfront using
  pre-interest balances, but month 1's actual minimums are computed
  post-interest-accrual and could exceed that estimate. Feasibility is now
  checked every month against the real (interest-accrued) minimums.
- Found and fixed a real crash: submitting the payment form with
  principal/interest portions left blank sent `""` (not absent), which hit
  `Decimal.new("")` directly in `Payments.log_payment/4` before Ecto's
  changeset cast could normalize it to `nil`.
- `mix test`/`mix phx.server` verified end-to-end against SQLite, including a
  full click-through LiveView test suite (add/edit debt, log payment, mark
  paid, log-all-balances, switch charts/strategies, change budget).

## Phase 6 — Self-hosting / Docker

- [x] Multi-stage `Dockerfile` (via `mix phx.gen.release --docker`, then
      customized: `/data` volume, default `DATABASE_PATH`)
- [x] `docker-compose.yml` (SQLite-only, the default)
- [x] `docker-compose.postgres.yml` (overlay adding a `postgres` service +
      `DATABASE_URL`, run with `-f docker-compose.yml -f docker-compose.postgres.yml`)
- [x] `.env.example` finalized (`SECRET_KEY_BASE`, `PORT`, `PHX_HOST`,
      `DATABASE_PATH`/`DATABASE_URL`/`POOL_SIZE`, `POSTGRES_PASSWORD`)
- [x] `DebtReliefTracker.Release.migrate/0` fixed to target only the
      configured repo (it's generated against `:ecto_repos`, which lists
      both `Repo.Sqlite` and `Repo.Postgres` -- migrating the inactive one
      would fail to connect). Extracted the shared "which repo is active"
      logic into `DebtReliefTracker.Repo.configured_repo/0`, used by both
      `Application.start/2` and `Release.migrate/0`.

Verified without Docker itself (still no local Docker binary in this
environment -- flagged in ADR 0003): built a real `MIX_ENV=prod mix release`
and ran `bin/debt_relief_tracker start` against a fresh `DATABASE_PATH`, with
`RELEASE_NAME` set (as the release scripts do automatically). Confirmed
migrations ran automatically on boot (the `Ecto.Migrator` child's
`skip_migrations?/0` check), the default workspace + placeholder debts were
seeded, and the dashboard served correctly at `/`. This exercises the exact
migration-on-boot path the Docker image relies on; the Docker build/run
itself (image size, base-image package needs) still needs a real Docker
environment to confirm.

## Phase 7 — Optional OIDC auth & sharing

- [x] `assent`-based OIDC login flow (`DebtReliefTrackerWeb.OIDC`,
      `AuthController`), gated entirely on `OIDC_ISSUER` /
      `OIDC_CLIENT_ID` / `OIDC_CLIENT_SECRET` all being set
      (`OIDC.enabled?/0` is the single check everything else uses)
- [x] Per-user workspace creation on first login
      (`Accounts.get_or_create_user_from_oidc!/1`)
- [x] Workspace sharing by email (`Accounts.share_workspace_with_email/2`,
      a small form in `DashboardLive`'s header, only shown to the owner of
      the currently-viewed workspace)
- [x] Workspace switcher (`<select>` in the header, only rendered when
      `length(@workspaces) > 1`)
- [x] `DashboardLive.mount/3` redirects to `/auth/login` when OIDC is
      enabled and the session has no `user_id`; no-auth mode is completely
      unaffected (verified: dev server still boots straight to the
      dashboard with no login wall when OIDC env vars are unset)

Verification limits: the actual OIDC redirect → provider → callback →
token/userinfo exchange can't be tested end-to-end without a real IdP, which
this environment doesn't have. What *is* tested (56 total tests, all
passing): every `Accounts` function (user/workspace creation, idempotency,
sharing, workspace resolution), `AuthController`'s login/logout paths that
don't require reaching a provider (no-op when disabled, session clearing),
and `DashboardLive`'s full session-driven behavior with OIDC "enabled" via
config (login gate, workspace switcher, ownership-gated sharing UI) --
everything downstream of a session that already has a `user_id`, which is
what the rest of the app actually depends on. Before relying on this in
production, do one real login against your chosen provider and confirm the
callback exchange succeeds.

## Phase 8 — Currency, activity log, CSV export, auto-logged payments

Post-initial-build additions, not part of the original `minimum.md` feature
list:

- [x] `Settings.currency` (already existed, defaulted to `"USD"`, but was
      never read anywhere) is now wired through: a `<select>`,
      `format_money/2` takes a currency and looks up a small symbol map
      (`USD`/`EUR`/`GBP`/`CAD`/`AUD`/`JPY`), and the pushed Chart.js config
      carries `currency` so the `PlanChart` hook's `Intl.NumberFormat`
      tick/tooltip formatters match. Originally an inline header control per
      the "not enough surface area to justify a settings page" precedent from
      ADR 0002; later moved into the settings modal (owner-only edit) once
      workspace renaming and member management joined it there -- see the
      updated ADR 0002 note.
- [x] Activity log UI: a 4th modal (`ActivityLog.list_recent/2`, already
      existed and was already fed by every mutation, just never surfaced),
      stream-backed via the existing `<.table>` core component, with a
      small per-action-type human-readable formatter in `DashboardLive`
- [x] CSV export: `DebtReliefTracker.CSVExport` (two separate downloads --
      debts and payments have different shapes) via `NimbleCSV`, served by
      a new plain `ExportController`/`GET /export/*.csv` (a LiveView can't
      force a browser file download itself), linked from the rail
- [x] Auto-logged payments (installment debts only -- revolving has no
      deterministic scheduled amount): per-debt `auto_log_mode`
      (`:off`/`:confirm`/`:automatic`) + `due_day`, sharing one pure
      due-ness check (`Debts.DueSchedule.due?/2`) between two paths --
      `:confirm` shows a "payment due" prompt in the "This month" card
      (computed fresh on every mount/refresh, no background process),
      `:automatic` is posted unattended by `DuePayments.Scheduler`, a plain
      `GenServer` (this app's first scheduled job -- no `Oban`, proportionate
      to "check hourly whether a date has passed") polling
      `DuePayments.post_due_payment/4` and broadcasting over `Phoenix.PubSub`
      so an open dashboard reflects it without a manual reload.
      `Payments.log_payment/5` gained an `:action` option so auto-posted
      payments log a distinct `:payment_auto_logged` activity-log action
      (vs. human-driven `:payment_logged`); `:due_payment_skipped` covers
      confirm-mode's "Skip this month". `last_due_handled_on` (per debt)
      makes the due-ness check resilient to a missed poll -- compares dates
      rather than requiring an exact-day match, so a container stopped over
      the due date still catches up on the next check instead of silently
      skipping that cycle.
- [x] Onboarding tutorial: a skippable, one-time spotlight walkthrough of the
      dashboard (add a debt, the debt list, the budget input, the chart-type
      and strategy switchers, settings). Tracked via a new `tutorial_seen`
      boolean on `Accounts.User` rather than `Settings` (workspace-scoped) --
      this app has no per-authenticated-user record in no-auth mode
      (`current_user` is `nil` there per ADR 0002), but
      `Accounts.ensure_default_workspace!/0` already resolves a real
      singleton `User` row for that mode, now exposed as
      `Accounts.get_default_user!/0` and used as the tutorial's "current
      user" when there's no OIDC session. No tour library added -- a
      `TutorialOverlay` JS hook (same `phx-update="ignore"` +
      `pushEvent`/`handleEvent` shape as `PlanChart`) positions a spotlight
      and tooltip against the target element's `getBoundingClientRect()`,
      since that's client-side-only information LiveView can't compute
      itself. "View tutorial again" in the settings modal resets
      `tutorial_seen` and restarts it.

## Phase 9 — Retirement roadmapping

Post-initial-build addition: a 6th chart type comparing how each debt payoff
strategy affects long-run retirement savings, not just debt payoff itself.

- [x] Retirement profile fields added to `Settings.Setting` (one row per
      workspace, same as `monthly_budget`/`currency` -- no new context, per
      the reuse guideline) rather than `Accounts.User`: `current_age`,
      `retirement_age` (nullable, doubling as the "onboarding not completed"
      signal), `current_retirement_savings`, `monthly_retirement_contribution`,
      `monthly_gross_income`, `post_debt_investment_pct` (default 15%, the
      common "invest 15% of income once debt-free" rule of thumb),
      `expected_annual_return_pct` (default 7%), and
      `retirement_onboarding_dismissed`. A dedicated `Setting.retirement_changeset/2`
      requires the profile fields as a group (used by the onboarding/edit
      modal); the general `changeset/2` leaves them optional.
- [x] `DebtReliefTracker.Planning.Retirement` -- a pure calculation module
      alongside `Planning`/`Debts.Calculations` -- projects monthly
      compound-growth balances to retirement. Each strategy has a
      "debt-free month" (`total_months` from `Planning.simulate/4`): before
      it, the contribution is whatever the user currently invests; from it
      onward, it switches to the recommended post-debt rate
      (`post_debt_investment_pct` of `monthly_gross_income`) for the rest of
      the horizon. A strategy that pays off debt sooner switches to the
      (larger) post-debt contribution sooner and compounds longer at that
      rate -- the mechanism that makes a faster strategy project a bigger
      nest egg. The baseline line never switches, for comparison.
- [x] `Charts.build/6` became `Charts.build/7` (a `settings` parameter added
      to every clause) with a new `:retirement_roadmap` clause: one line per
      strategy plus a dashed baseline, x-axis in age rather than month
      count, reusing the existing `@palette`/`@total_line_color` so no
      `PlanChart` JS hook changes were needed.
- [x] Onboarding is a dismissible banner on the dashboard (not a
      mount-blocking modal -- tried initially, but forcing a modal open on
      every mount with no profile set would have collided with the existing
      tutorial-overlay auto-start and made the dashboard unusable in
      existing/manual-testing flows until dismissed) plus a "Set up/Edit
      retirement profile" entry in the Settings modal, both opening the same
      `:retirement_onboarding` modal via the standard
      open/validate/save `handle_event` + changeset-backed `<.form>` pattern
      used by add/edit-debt.

## Verification

- [x] `mix precommit` passing (130 tests; compile --warning-as-errors,
      deps.unlock --unused, format, test)
- [x] Manual pass against SQLite (`mix phx.server` + a real prod release run)
- [ ] Manual pass against Postgres (`DATABASE_URL` set) -- adapter switch
      itself verified (Phase 2), but no local Postgres instance was
      available in this environment to run the app against one live
- [ ] Docker build/run verified on a machine with Docker -- the
      release/migration path it depends on is verified (Phase 6), Docker
      itself is not
