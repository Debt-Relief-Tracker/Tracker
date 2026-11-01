# Hologram UI conventions (roadmap Phase 10, ADR 0007)

The new dashboard is `DebtReliefTrackerWeb.Holo.DashboardPage` at `/app`
(the LiveView at `/` stays until parity). It only owns shared state and
layout; each feature is a stateful component under
`lib/debt_relief_tracker_web/holo/components/`. **Port behavior from
`lib/debt_relief_tracker_web/live/dashboard_live.ex`** (its `handle_event`s,
template section and `*_modal` functions) and match its look (same Tailwind /
daisyUI classes; mobile-default classes unprefixed, desktop behind `sm:`).

Hologram is NOT LiveView: read `deps/hologram/usage-rules.md` first.

## Page state (read via props, change via page actions)

- `snapshot` -- `Storage` snapshot (cents / basis points / ISO date strings /
  string enums). Only source of financial data. Shape: `lib/debt_relief_tracker/storage.ex`
  and `storage/snapshot.ex`.
- `account` -- `%{oidc_enabled, signed_in, user: %{id, display_name, email, tutorial_seen, theme, is_admin}, workspace: %{id, name}, workspaces: [%{id, name}]}`.
- `modal` -- `nil | %{type: atom, ...}`; page renders the matching modal component.
- `strategy` -- `:cash_flow | :snowball | :avalanche`.

Page actions to target with `target: "page"`: `:open_modal %{modal: map}`,
`:close_modal`, `:snapshot_updated %{snapshot: s}`, `:change_failed %{error: e}`,
`:account_updated %{account: a}`, `:select_strategy %{strategy: a}`.
Adding a new page action/state key is allowed but keep it minimal -- the page
file is shared; prefer keeping state inside your own component.

## Changing data

Never write to Ecto from a component. Send a `Storage` change (vocabulary in
`Storage` moduledoc) through a command on your component:

    middleware DebtReliefTrackerWeb.Holo.Auth      # REQUIRED on any component with commands

    def command(:save, %{change: change}, server) do
      case DebtReliefTrackerWeb.Holo.Context.apply_change(server, change) do
        {:ok, snapshot} ->
          server |> put_action(name: :snapshot_updated, target: "page", params: %{snapshot: snapshot})
                 |> put_action(name: :close_modal, target: "page")
        {:error, error} -> put_action(server, :save_failed, error: error)
      end
    end

Server-only data (accounts, workspaces, sharing, preferences) goes through
`Context` / the `Accounts` context in a command, never from client-supplied
workspace or user ids -- always derive them with `Context.workspace/1` and
`Context.user/1`. If you need a new `Storage` change type, add it to
`Storage` + `Storage.Plain` (+ tests) in your own commit; keep it additive.

## Client-safe code rules

Anything reachable from a component's template/actions is compiled to JS.
It may NOT use: `Decimal`, `Date`/`DateTime`/`Calendar`, floats, `Regex`, or
anything Ecto. Use `Engine.*` (integer cents, basis points, `Engine.Days`
tuples), `Holo.Format`, `Holo.Summary`, `Engine.FromSnapshot`. Code behind a
`command/3` runs on the server and may use anything. Check
`deps/hologram/llms-full.txt` "Client Runtime" for supported functions; when
unsure, compile (below) -- unsupported calls surface there or in a test.
Templates (`~HOLO`) have `{%if}`, `{%else}`, `{%for pat <- list}` only (no
case; use a `for` with a pattern to filter). Interpolate with `{expr}`.
Every key element gets a unique DOM `id` (tests select on them).
JS goes in `assets/js/` as small facade files behind an Elixir module; no
app logic in JS and no inline `<script>` in templates.

## Money and forms

Inputs hold text; parse dollars->cents in the component with integer string
math (no Decimal/float). Put reusable parse/format helpers in
`Holo.Format` (additive edits only -- other agents add there too).

## Testing

- `mix test` already sets `HOLOGRAM_START=1` and compiles Hologram.
- Pure helpers: plain ExUnit (`test/debt_relief_tracker_web/holo/...`).
- Actions/commands are plain functions: unit-test them directly.
- Server render: `ConnCase` `get("/app")` only shows the *initial* state
  (no modal open); test your component's template by rendering it with the
  Hologram renderer / the test harness if available, else via its pure
  helpers + action tests. Port the *behavior* of the matching tests in
  `test/debt_relief_tracker_web/live/dashboard_live_test.exs`.
- Browser tests (if the `:browser` harness exists on your base) are tagged
  `@tag :browser` and excluded by default.

## Hard rules for agents (live app, real data)

- NEVER run `mix phx.server`, `mix holo`, or any server; never touch the dev
  database (`/home/kmenigoz/repos-priv/debt-relief/tracker/data`). You work in
  your own git worktree with its own test DB. `mix ecto.migrate` is not
  needed; if you believe a migration is required, STOP and report instead.
- Do not edit files outside your ownership list except additive edits to
  shared helpers (`Holo.Format`, `Storage`, `Storage.Plain`, `Engine.*`).
- Do not touch `live/dashboard_live.ex` or the LiveView tests (they remain
  the reference). Keep `mix test` green and `mix compile --warning-as-errors`
  clean before committing.
- Commit to your worktree branch with
  `Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>`. Final report:
  <=200 words -- branch, files, what works, what you could not verify, any
  decision the owner must make.

## Browser tests

Real-Chromium tests of the Hologram UI. They are tagged `:browser`, excluded
from plain `mix test` (see `test/test_helper.exs`), and run with:

    (cd test/browser && npm install)     # once; Playwright lives here, not in assets/
    mix test --include browser           # or: mix test --include browser path/to_test.exs

How it works: `DebtReliefTracker.BrowserCase` (`test/support/browser_case.ex`)
starts a second Bandit listener on a free loopback port in front of the
supervised endpoint (config keeps `server: false`; never `mix phx.server` /
`mix holo`), checks out the Ecto sandbox in shared mode so the server sees
what the test seeded (so browser tests are never `async`), and drives headless
Chromium through `test/browser/driver.mjs` (playwright-core over a Port).
The driver uses the Chromium already cached in `~/.cache/ms-playwright`
(override with `CHROMIUM_PATH`), so no download is needed. The test DB is the
SQLite test database only.

Writing one:

    use DebtReliefTracker.BrowserCase      # tags the module :browser

    test "...", ctx do
      # seed with Debts/Accounts exactly like ConnCase tests do, then:
      ctx
      |> visit_page(DebtReliefTrackerWeb.Holo.DashboardPage)  # waits for mount + WS + SSE
      |> click("#some-button")
      |> fill("#some-input", "12.50")
      |> assert_selector("#some-modal")
      |> assert_text("#this-month-card", "Visa")
    end

Helpers: `visit_page/2`, `visit/2` (raw path), `click/2`, `fill/3`, `text/2`,
`current_path/1`, `assert_selector/2`, `refute_selector/2`, `assert_text/3`.
All pipe the context; assertions wait (default 10s, `BROWSER_TEST_TIMEOUT_MS`)
and raise on timeout. Select on the element `id`s your component defines.
`test/support/browser/counter_page.ex` is a test-only page for exercising
client-side actions when the real dashboard has no suitable control yet.
