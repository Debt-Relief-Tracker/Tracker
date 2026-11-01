defmodule DebtReliefTracker.BrowserCase.CounterPage do
  @moduledoc """
  Test-only Hologram page (compiled only in `:test`, via `test/support`) that
  gives the browser smoke tests a client-side interaction to drive end to end:
  a click runs an action in the browser and re-renders, and `:open_modal` /
  `:close_modal` follow the same `modal: nil | map` convention as the real
  `Holo.DashboardPage` (whose stubs don't expose a button yet).
  """

  use Hologram.Page

  route "/__browser_test/counter"
  layout DebtReliefTrackerWeb.Holo.Layout

  def init(_params, component, _server) do
    component
    |> put_state(:count, 0)
    |> put_state(:modal, nil)
  end

  def template do
    ~HOLO"""
    <div id="counter-page">
      <p id="count">Count: {@count}</p>
      <button id="increment" $click="increment">Increment</button>
      <button id="open-modal" $click={:open_modal, modal: %{type: :demo}}>Open</button>
      {%if @modal}
        <div id="demo-modal">
          <p>Demo modal</p>
          <button id="close-modal" $click="close_modal">Close</button>
        </div>
      {/if}
    </div>
    """
  end

  def action(:increment, _params, component),
    do: put_state(component, :count, component.state.count + 1)

  def action(:open_modal, %{modal: modal}, component), do: put_state(component, :modal, modal)
  def action(:close_modal, _params, component), do: put_state(component, :modal, nil)
end
