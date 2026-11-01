defmodule DebtReliefTrackerWeb.Holo.ChartJS do
  @moduledoc """
  Elixir facade over `assets/js/chart_facade.mjs` (Chart.js). The only
  module that talks to Chart.js; components go through
  `DebtReliefTrackerWeb.Holo.Components.Chart`.

  Hologram bundles `chart_facade.mjs` and the `chart.js` npm package it
  imports with its own esbuild, resolving the package from
  `assets/node_modules` (so `npm install --prefix assets` must run before
  `mix compile` -- see the Dockerfile). No CDN.

  Like all Hologram JS interop these calls only do something in the browser,
  from an action; on the server (`init/3`, tests) they are no-ops that return
  `:ok`. Configs come from `DebtReliefTracker.Engine.Charts`.
  """

  use Hologram.JS

  js_import from: "../../../assets/js/chart_facade.mjs", as: :ChartFacade

  @doc """
  Draws `variants` (`%{light: config, dark: config}`, see
  `Engine.Charts.theme_variants/1`) into the element with DOM id
  `container_id`, replacing any chart already there.
  """
  def render(container_id, variants), do: JS.call(:ChartFacade, :render, [container_id, variants])

  @doc "Removes the chart drawn into `container_id`, if any."
  def destroy(container_id), do: JS.call(:ChartFacade, :destroy, [container_id])
end
