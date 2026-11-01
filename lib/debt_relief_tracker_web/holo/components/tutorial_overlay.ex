defmodule DebtReliefTrackerWeb.Holo.Components.TutorialOverlay do
  @moduledoc """
  First-run tutorial overlay: dims the page and cuts a hole around the real
  element the current step points at, plus a card with Next/Back/Skip.

  Steps are `Holo.Tutorial`; measuring is `Holo.TutorialOverlayJS`. The
  overlay auto-starts on client mount when `account.user.tutorial_seen` is
  false (`init/3` queues `:auto_start`, which only runs in the browser).
  The page's `:restart_tutorial` action forwards `:restart` here.
  """

  use Hologram.Component

  middleware DebtReliefTrackerWeb.Holo.Auth

  alias DebtReliefTracker.Accounts
  alias DebtReliefTrackerWeb.Holo.Context
  alias DebtReliefTrackerWeb.Holo.Tutorial
  alias DebtReliefTrackerWeb.Holo.TutorialOverlayJS

  prop :snapshot, :map
  prop :account, :map

  def init(props, component, _server) do
    component =
      component
      |> put_state(:step, nil)
      |> put_state(:view, nil)
      |> put_state(:backdrop_style, "")
      |> put_state(:card_style, "")

    if props.account.user.tutorial_seen do
      component
    else
      put_action(component, :auto_start)
    end
  end

  def template do
    ~HOLO"""
    <div id="tutorial-overlay">
      {%if @view}
        <div id="tutorial-backdrop" class="tutorial-overlay-backdrop" style={@backdrop_style}></div>
        <div id="tutorial-card" class="tutorial-overlay-card bg-base-100 text-base-content rounded-lg shadow-xl p-4 w-80" style={@card_style} data-target={@view.target}>
          <p id="tutorial-progress" class="text-xs opacity-60 mb-1">{@view.progress}</p>
          <h3 id="tutorial-title" class="font-semibold mb-2">{@view.title}</h3>
          <p id="tutorial-body" class="text-sm mb-4">{@view.body}</p>
          <div class="flex items-center justify-between gap-2">
            <button type="button" id="tutorial-skip" class="btn btn-ghost btn-sm min-h-9 sm:min-h-0" $click={:skip}>Skip</button>
            <div class="flex items-center gap-2">
              {%if @view.first?}
                <button type="button" id="tutorial-back" class="btn btn-soft btn-sm invisible" $click={:prev}>Back</button>
              {%else}
                <button type="button" id="tutorial-back" class="btn btn-soft btn-sm" $click={:prev}>Back</button>
              {/if}
              <button type="button" id="tutorial-next" class="btn btn-primary btn-sm min-h-9 sm:min-h-0" $click={:next}>{@view.next_label}</button>
            </div>
          </div>
        </div>
      {/if}
    </div>
    """
  end

  # --- actions ---------------------------------------------------------------

  # Queued by init/3, so it only ever runs on client mount.
  def action(:auto_start, _params, component), do: show_step(component, 0)

  # Sent by the page's :restart_tutorial (settings "View tutorial again").
  # Also resets to the comparison chart (show_step may only queue ONE action,
  # so the chart switch takes the slot; step 1 has no target to measure).
  def action(:restart, _params, component) do
    component
    |> put_command(:set_seen, seen: false)
    |> show_step(0, %{chart_type: :comparison})
  end

  def action(:next, _params, component) do
    case Tutorial.next(component.state.step) do
      {:step, index} -> show_step(component, index)
      :finish -> finish(component)
    end
  end

  def action(:prev, _params, component) do
    {:step, index} = Tutorial.prev(component.state.step)
    show_step(component, index)
  end

  def action(:skip, _params, component), do: finish(component)

  def action(:seen_saved, %{account: account}, component) do
    put_action(component, name: :account_updated, target: "page", params: %{account: account})
  end

  # Re-measure after the DOM settles (a chart switch or scroll may move the
  # target). A no-op when the tutorial isn't showing.
  # Re-measure after the DOM settles (also poked by the JS facade on
  # resize/scroll/DOM change). A no-op when the tutorial isn't showing.
  def action(:reposition, _params, component) do
    case component.state.view do
      nil ->
        component

      view ->
        layout = TutorialOverlayJS.layout(view.target)

        component
        |> put_state(:backdrop_style, layout["backdrop_style"])
        |> put_state(:card_style, layout["card_style"])
    end
  end

  # A handler can queue only ONE follow-up action, so exactly one is chosen:
  # a chart switch for plan_panel, else none. Measuring is driven by the JS
  # facade, which watches the card's data-target and the DOM and dispatches
  # :reposition itself.
  defp show_step(component, index, step \\ nil) do
    step = step || Tutorial.step(index)
    view = Tutorial.view(index)

    component =
      component
      |> put_state(:step, index)
      |> put_state(:view, view)

    component =
      if view.target == nil do
        component
        |> put_state(:backdrop_style, Tutorial.backdrop_style())
        |> put_state(:card_style, Tutorial.centered_card_style())
      else
        component
      end

    cond do
      step.chart_type != nil ->
        put_action(component,
          name: :select_chart_type,
          target: "plan_panel",
          params: %{chart_type: step.chart_type}
        )

      true ->
        component
    end
  end

  defp finish(component) do
    component
    |> put_state(:step, nil)
    |> put_state(:view, nil)
    |> put_command(:set_seen, seen: true)
  end

  # --- commands ----------------------------------------------------------------

  # Persists tutorial_seen for the signed-in user (the implicit default user in
  # no-auth mode) and refreshes the page's account so it stays in sync.
  def command(:set_seen, %{seen: seen}, server) do
    user = Context.user(server) || Accounts.get_default_user!()
    {:ok, _user} = Accounts.set_tutorial_seen(user, seen)

    put_action(server, name: :seen_saved, params: %{account: Context.account(server)})
  end
end
