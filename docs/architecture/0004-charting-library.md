# ADR 0004: Charting library (Chart.js via a LiveView hook)

## Status

Accepted. Supersedes the charting portion of the original Phase 5 plan.

## Context

The initial build (docs/plan.md Phase 5) rendered the four payoff-plan
charts as hand-rolled inline SVG — plain bars and polylines computed
server-side in HEEx — specifically to avoid adding a JS charting dependency
and keep the self-hosted footprint light.

In practice this was too limited: a single polyline per chart couldn't show
more than one series (e.g. "total balance over time" with no per-debt
detail), had no legend/tooltips, and comparison charts could only sensibly
show one metric at a time. The user asked directly for more capable charts
with more information, which is a explicit reversal of the original
"SVG-only" tradeoff.

## Decision

- **Library**: [Chart.js](https://www.chartjs.org/), added as an
  `assets/package.json` dependency (`npm install --prefix assets`) and
  bundled by the existing esbuild pipeline — no CDN, no separate JS build
  tool, still a single self-contained asset bundle. `assets/package.json`
  didn't exist before this; it's now the first real npm-managed frontend
  dependency in the project (heroicons/daisyui/topbar are still hand-vendored
  in `assets/vendor/`, unaffected).
- **Server → client data flow**: `DebtReliefTrackerWeb.Charts.build/6` is a
  pure function that returns `{message, config}` -- `config` is a full
  Chart.js config map (`%{type:, data:, options:}`) for whichever chart type
  is selected, `message` is a user-facing fallback string when there's
  nothing to plot (no debts yet, budget insufficient, etc). `DashboardLive`
  pushes `config` to the client via `push_event(socket, "plan-chart-data", config)`
  whenever the relevant state changes (chart type, strategy, budget, or any
  debt/payment mutation).
- **Client**: `assets/js/plan_chart_hook.js` defines a `PlanChart` LiveView
  hook. It subscribes to the `plan-chart-data` event once in `mounted()` and,
  on every event, **destroys and recreates** the Chart.js instance rather
  than trying to patch it in place — bar → line → doughnut configs aren't
  structurally compatible, so a full teardown/rebuild is simpler and more
  robust than partial-update logic.
- **DOM lifetime**: the `<canvas id="plan-chart" phx-hook="PlanChart" phx-update="ignore">`
  element is only removed from the DOM when there's nothing to plot (the
  `@chart_message` fallback shows instead). As long as some chart is
  showing, switching chart types re-uses the same canvas/hook instance —
  only `push_event` fires, not a hook remount — which is what makes the
  destroy/recreate-on-event approach in the hook necessary and sufficient.
- **Four chart types**, chosen to actually use Chart.js's capabilities
  rather than just re-skinning the old SVG shapes:
  - **Comparison**: dual-axis bar chart (interest $ on one axis, months to
    payoff on the other) across the three strategies, instead of
    interest-only.
  - **Simulation**: one line per debt (ending balance per month) plus a
    dashed "Total" line, instead of a single aggregate line -- this is the
    direct fix for "that's not enough info."
  - **Freed cash flow**: filled area chart (unchanged shape, nicer
    rendering/tooltips).
  - **Interest vs. principal**: doughnut chart with a legend, instead of a
    plain CSS stacked div.

## Consequences

- `app.js`'s bundle grew meaningfully (~130KB → ~330KB minified) from
  including Chart.js. Acceptable for a self-hosted personal finance tool
  serving a handful of users at a time; revisit only if this becomes a real
  complaint.
- Chart colors are a small fixed palette, not yet adaptive to the
  light/dark theme toggle (ADR-adjacent to the theme work in docs/plan.md
  Phase 5) -- a known, accepted gap for now.
- Testing charts now spans two layers: `DebtReliefTrackerWeb.Charts` is
  fully unit-testable (pure data in, config map out — see
  `test/debt_relief_tracker_web/charts_test.exs`), and `DashboardLive`'s
  wiring is verified via `assert_push_event/3` (confirming the right
  `type` gets pushed for each chart-type switch — see
  `test/debt_relief_tracker_web/live/dashboard_live_test.exs`). The actual
  rendered pixels (Chart.js drawing to canvas) are not exercised by
  `Phoenix.LiveViewTest` at all, since that requires a real browser; this
  wasn't visually verified in a real browser in this environment.
- Discovered while adding these tests: `Payments.log_payment/4` had a
  pre-existing bug where the principal/interest split used to adjust the
  debt's balance was never persisted onto the `Payment` row itself unless
  the caller explicitly supplied it -- silently breaking lifetime
  interest/principal reporting for the common "amount only" payment form.
  Fixed as part of this work (see `docs/roadmap.md` Phase 5 notes).
