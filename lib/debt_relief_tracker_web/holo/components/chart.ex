defmodule DebtReliefTrackerWeb.Holo.Components.Chart do
  @moduledoc """
  A Chart.js chart, or a message when there's nothing to plot. Reusable:
  give it a `cid`, a page-unique `dom_id` and the current `message`, then
  have the owning component send it the config:

      <Chart cid="plan_chart" dom_id="plan-chart" message={@chart_message} />

      put_action(component, name: :draw, target: "plan_chart", params: %{config: config})
      put_action(component, name: :clear, target: "plan_chart")

  `config` is a Chart.js config map from `DebtReliefTracker.Engine.Charts`;
  the light/dark variants are derived here and the facade redraws when the
  theme flips. The container stays in the template (hidden while a message
  shows), so Hologram re-renders never disturb the canvas the facade put
  inside it.
  """

  use Hologram.Component

  alias DebtReliefTracker.Engine.Charts
  alias DebtReliefTrackerWeb.Holo.ChartJS

  prop :dom_id, :string, required: true
  prop :message, :string, default: nil

  def template do
    ~HOLO"""
    {%if @message}
      <p id="{@dom_id}-message">{@message}</p>
    {/if}
    <div id={@dom_id} class={container_class(@message)}></div>
    """
  end

  def container_class(nil), do: "relative h-full min-h-[22rem]"
  def container_class(_message), do: "hidden"

  def action(:draw, %{config: config}, component) do
    ChartJS.render(component.props.dom_id, Charts.theme_variants(config))
    component
  end

  def action(:clear, _params, component) do
    ChartJS.destroy(component.props.dom_id)
    component
  end
end
