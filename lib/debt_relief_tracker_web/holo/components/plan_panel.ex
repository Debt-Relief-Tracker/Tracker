defmodule DebtReliefTrackerWeb.Holo.Components.PlanPanel do
  @moduledoc """
  The dashboard's main panel (port of `DashboardLive`'s `<main>`): summary
  stat cards, the this-month card, the monthly budget input + budget mode,
  the chart-type picker, the strategy switcher and the plan chart.

  Inputs are the `snapshot` and `strategy` props plus this component's own
  state (chart type, the budget being typed). Everything shown is derived
  once per input change by `Holo.Plan` and kept in `:view`, so ordinary
  re-renders cost nothing; the simulations are cached in `:derived` (keyed
  on snapshot + budget), so switching chart type or strategy doesn't re-run
  them. The chart is drawn by the `plan_chart` `Holo.Components.Chart` from
  an action, since JS interop only runs there.

  Performance note (Hologram 0.12.4): every client action console.logs the
  duration of every function call it makes, which makes a full re-plan of a
  long payoff (hundreds of months x 3 strategies) take ~2 s in the browser;
  hence the cache and the server-computed first chart.

  Actions other components may target (`target: "plan_panel"`):

    * `:select_chart_type` -- `%{chart_type: atom}` (one of
      `Engine.Charts.chart_types/0`); e.g. the tutorial switching charts.
    * `:plan_inputs_changed` -- recompute after the page's `snapshot` or
      `strategy` changed. The page chains it from `:snapshot_updated` and
      `:select_strategy`.

  The strategy itself lives in page state; the switcher targets the page's
  `:select_strategy`. Budget and budget-mode changes are persisted with the
  `{:update_settings, ...}` Storage change.
  """

  use Hologram.Component

  alias DebtReliefTracker.Engine.Charts
  alias DebtReliefTrackerWeb.Holo.Components.Chart
  alias DebtReliefTracker.VaultEnv
  alias DebtReliefTrackerWeb.Holo.Context
  alias DebtReliefTrackerWeb.Holo.DataPath
  alias DebtReliefTrackerWeb.Holo.Format
  alias DebtReliefTrackerWeb.Holo.Plan
  alias DebtReliefTrackerWeb.Holo.QuietJS

  middleware DebtReliefTrackerWeb.Holo.Auth

  prop :snapshot, :map
  prop :account, :map
  prop :strategy, :atom
  prop :e2ee, :boolean, from_context: :e2ee

  @save_error "Couldn't save your budget settings -- please try again."

  # Server, first render: the cards and the first chart's config are
  # computed here, so the browser draws the chart on mount without
  # re-running the simulations. The client-side cache (`:derived`) starts
  # empty and is filled by the first action that needs it -- the full plan
  # is not shipped in the page.
  def init(props, component, _server) do
    %Date{year: year, month: month, day: day} = Date.utc_today()
    init_state(props, component, {year, month, day}, props.snapshot)
  end

  # E2EE: mounted in the browser after unlock. The page queues
  # `:plan_inputs_changed` right after unlocking, so only a cheap empty plan
  # is computed here (the real one would otherwise run twice).
  def init(props, component) do
    today = VaultEnv.today_iso()

    ymd =
      {String.to_integer(String.slice(today, 0, 4)), String.to_integer(String.slice(today, 5, 2)),
       String.to_integer(String.slice(today, 8, 2))}

    init_state(props, component, ymd, %{props.snapshot | debts: [], payments: []})
  end

  defp init_state(props, component, today, snapshot) do
    component =
      put_state(component,
        chart_type: :comparison,
        budget_draft: nil,
        budget_focused?: false,
        mode_pending: nil,
        save_error: nil,
        today: today
      )

    derived = derive(component, snapshot, props.strategy)

    component
    |> put_state(view: Plan.view(derived), derived: nil)
    |> draw(derived)
  end

  def template do
    ~HOLO"""
    <div id="plan-panel" class="flex flex-col gap-4">
      <div id="summary-stats" class="stats stats-vertical sm:flex sm:flex-wrap shadow w-full">
        <div id="stat-total-paid" class="stat sm:w-auto sm:grow sm:basis-44 bg-purple-600 text-white">
          <div class="stat-figure"><span class="hero-currency-dollar size-6"></span></div>
          <div class="stat-title text-purple-100">Total Paid</div>
          <div class="stat-value text-2xl">{Format.money(@view.stats.total_paid, @view.currency)}</div>
        </div>
        <div id="stat-interest-paid" class="stat sm:w-auto sm:grow sm:basis-44 bg-orange-600 text-white">
          <div class="stat-figure"><span class="hero-face-frown size-6"></span></div>
          <div class="stat-title text-orange-100">Interest Paid</div>
          <div class="stat-value text-2xl">{Format.money(@view.stats.interest_paid, @view.currency)}</div>
        </div>
        <div id="stat-debt-remaining" class="stat sm:w-auto sm:grow sm:basis-44 bg-yellow-500 text-white">
          <div class="stat-figure"><span class="hero-building-library size-6"></span></div>
          <div class="stat-title text-yellow-100">Debt Remaining</div>
          <div class="stat-value text-2xl">{Format.money(@view.stats.debt_remaining, @view.currency)}</div>
        </div>
        <div id="stat-payoff-date" class="stat sm:w-auto sm:grow sm:basis-44 bg-teal-600 text-white">
          <div class="stat-figure"><span class="hero-calendar size-6"></span></div>
          <div class="stat-title text-teal-100">Payoff Date</div>
          <div class="stat-value text-2xl">{@view.stats.payoff_date}</div>
          {%if @view.stats.payoff_months}
            <div class="stat-desc text-teal-100">{months_left(@view.stats.payoff_months)}</div>
          {/if}
        </div>
        {%if @view.stats.utilization_bp}
          <div id="stat-utilization" class="stat sm:w-auto sm:grow sm:basis-44 bg-pink-600 text-white">
            <div class="stat-figure"><span class="hero-chart-pie size-6"></span></div>
            <div class="stat-title text-pink-100">Credit Utilization</div>
            <div class="stat-value text-2xl">{Format.percent_bp(@view.stats.utilization_bp)}</div>
          </div>
        {/if}
      </div>

      <section id="this-month-card" class="border border-base-300 rounded p-4">
        <h2 class="font-semibold mb-1">This month</h2>
        {%if @view.this_month.message}
          <p id="this-month-message">{@view.this_month.message}</p>
        {/if}
        {%if @view.this_month.lines != []}
          <div id="this-month-lines" class="flex flex-wrap gap-4 text-sm">
            {%for line <- @view.this_month.lines}
              <div id="this-month-line-{line.debt_id}">
                <span class="font-medium">{line.name}</span>:
                pay {Format.money(line.payment, @view.currency)}
                {%if line.extra}
                  <span class="badge badge-primary badge-sm">extra</span>
                {/if}
              </div>
            {/for}
          </div>
        {/if}
      </section>

      <div id="plan-controls" class="flex flex-wrap items-center gap-4">
        <form id="budget-form" class="flex items-center gap-2" $submit="save_budget">
          <label for="budget-input" class="text-sm">{Plan.budget_label(mode(@mode_pending, @snapshot))}</label>
          <input
            id="budget-input"
            type="number"
            step="0.01"
            name="monthly_budget"
            value={budget_value(@budget_draft, @snapshot, mode(@mode_pending, @snapshot))}
            class="input input-sm w-28"
            $change="budget_changed"
            $change.debounce(600)="save_budget"
            $focus="budget_focused"
            $blur="budget_blurred"
          />
        </form>

        <div id="budget-mode" class="join">
          <button
            id="budget-mode-total"
            type="button"
            class={button_class("btn btn-xs join-item min-h-8 sm:min-h-0", mode(@mode_pending, @snapshot) == :total)}
            $click={:select_budget_mode, mode: :total}
          >
            Total
          </button>
          <button
            id="budget-mode-margin"
            type="button"
            class={button_class("btn btn-xs join-item min-h-8 sm:min-h-0", mode(@mode_pending, @snapshot) == :margin)}
            $click={:select_budget_mode, mode: :margin}
          >
            Margin
          </button>
        </div>

        <div id="chart-type-switcher">
          <div class="join hidden lg:flex">
            {%for type <- Charts.chart_types()}
              <button
                id="chart-type-{type}"
                type="button"
                class={button_class("btn btn-sm join-item", type == @chart_type)}
                $click={:select_chart_type, chart_type: type}
              >
                {Charts.chart_label(type)}
              </button>
            {/for}
          </div>
          <form class="lg:hidden">
            <select id="chart-type-select" name="type" class="select select-sm w-full" value="{@chart_type}" $change="chart_type_selected">
              {%for type <- Charts.chart_types()}
                <option value="{type}">{Charts.chart_label(type)}</option>
              {/for}
            </select>
          </form>
        </div>

        {%if Charts.strategy_dependent?(@chart_type)}
          <div id="strategy-switcher">
            <div class="join hidden lg:flex">
              {%for strategy <- Charts.strategies()}
                <button
                  id="strategy-{strategy}"
                  type="button"
                  class={button_class("btn btn-sm join-item", strategy == @strategy)}
                  $click={action: :select_strategy, target: "page", params: %{strategy: strategy}}
                >
                  {Charts.strategy_label(strategy)}
                </button>
              {/for}
            </div>
            <form class="lg:hidden">
              <select id="strategy-select" name="strategy" class="select select-sm w-full" value="{@strategy}" $change="strategy_selected">
                {%for strategy <- Charts.strategies()}
                  <option value="{strategy}">{Charts.strategy_label(strategy)}</option>
                {/for}
              </select>
            </form>
          </div>
        {/if}
      </div>

      {%if @save_error}
        <p id="budget-save-error" class="text-error text-sm">{@save_error}</p>
      {/if}

      <div id="plan-chart-panel" class="border border-base-300 rounded p-4 flex-1 min-h-[24rem]">
        <Chart cid="plan_chart" dom_id="plan-chart" message={@chart_message} />
      </div>
    </div>
    """
  end

  # --- template helpers -----------------------------------------------------

  def mode(nil, snapshot), do: Plan.budget_mode(snapshot)
  def mode(pending, _snapshot), do: pending

  def budget_value(nil, snapshot, mode), do: Plan.budget_input_value(snapshot, mode)
  def budget_value(draft, _snapshot, _mode), do: draft

  def button_class(base, true), do: base <> " btn-primary"
  def button_class(base, false), do: base

  def months_left(1), do: "1 month left"
  def months_left(months), do: "#{months} months left"

  # --- actions ----------------------------------------------------------------

  def action(:plan_inputs_changed, _params, component) do
    component |> settle_draft() |> refresh()
  end

  # Only the chart changes: reuses the cached simulations.
  def action(:select_chart_type, %{chart_type: chart_type}, component) do
    if chart_type in Charts.chart_types() do
      QuietJS.quiet()
      component = put_state(component, :chart_type, chart_type)

      derived =
        component.state.derived ||
          derive(component, component.props.snapshot, component.props.strategy)

      component |> put_state(:derived, derived) |> draw(derived)
    else
      component
    end
  end

  # The mobile <select> sends the option's string value.
  def action(:chart_type_selected, %{event: %{value: value}}, component) do
    case Enum.find(Charts.chart_types(), &(Atom.to_string(&1) == value)) do
      nil -> component
      chart_type -> put_action(component, :select_chart_type, chart_type: chart_type)
    end
  end

  def action(:strategy_selected, %{event: %{value: value}}, component) do
    case Enum.find(Charts.strategies(), &(Atom.to_string(&1) == value)) do
      nil ->
        component

      strategy ->
        put_action(component,
          name: :select_strategy,
          target: "page",
          params: %{strategy: strategy}
        )
    end
  end

  # Every keystroke re-plans locally (no round trip); saving is debounced.
  def action(:budget_changed, %{event: %{value: value}}, component) do
    component |> put_state(:budget_draft, value) |> refresh()
  end

  def action(:save_budget, _params, component) do
    snapshot = component.props.snapshot
    mode = mode(component.state.mode_pending, snapshot)
    saved = snapshot.settings.monthly_budget

    case Plan.draft_total(snapshot, component.state.budget_draft, mode) do
      {:ok, cents} when cents != saved ->
        save_settings(component, %{monthly_budget: cents})

      _unchanged_or_invalid ->
        component
    end
  end

  def action(:budget_focused, _params, component),
    do: put_state(component, :budget_focused?, true)

  def action(:budget_blurred, _params, component) do
    component = put_state(component, :budget_focused?, false)
    settled = settle_draft(component)

    # Re-plan only if dropping the draft changed the budget in use.
    if settled.state.budget_draft == component.state.budget_draft,
      do: settled,
      else: refresh(settled)
  end

  def action(:select_budget_mode, %{mode: mode}, component) when mode in [:total, :margin] do
    component =
      component
      |> put_state(mode_pending: mode, budget_draft: nil)
      |> save_settings(%{budget_mode: Atom.to_string(mode)})

    # E2EE: the ledger reply (`:settings_saved` -> page -> `:plan_inputs_changed`)
    # is this handler's one follow-up and re-plans anyway; `refresh/1` would take its slot.
    if DataPath.e2ee?(component), do: component, else: refresh(component)
  end

  def action(:settings_saved, %{snapshot: snapshot}, component) do
    component
    |> put_state(mode_pending: nil, save_error: nil)
    |> put_action(name: :snapshot_updated, target: "page", params: %{snapshot: snapshot})
  end

  def action(:save_failed, _params, component) do
    component
    |> put_state(mode_pending: nil, save_error: @save_error)
    |> refresh()
  end

  # Plaintext: the `:save_settings` command; E2EE: the page's ledger path.
  defp save_settings(component, attrs) do
    DataPath.save(component, :save_settings, %{attrs: attrs},
      changes: [{:update_settings, settings_attrs(attrs)}],
      ok: DataPath.ok(:settings_saved, "plan_panel"),
      error: DataPath.error(:save_failed, "plan_panel")
    )
  end

  # --- commands (server) -------------------------------------------------------

  def command(:save_settings, %{attrs: attrs}, server) do
    case Context.apply_change(server, {:update_settings, settings_attrs(attrs)}) do
      {:ok, snapshot} -> put_action(server, :settings_saved, snapshot: snapshot)
      {:error, _error} -> put_action(server, :save_failed)
    end
  end

  # Only the two settings this panel owns, whatever the client sent.
  defp settings_attrs(attrs) do
    Map.new(
      for {key, value} <- attrs,
          (key == :monthly_budget and is_integer(value)) or
            (key == :budget_mode and value in ["total", "margin"]),
          do: {key, value}
    )
  end

  # --- internals ----------------------------------------------------------------

  # An input changed (snapshot, strategy, budget, mode): re-run the
  # simulations once, cache them, re-derive the cards and redraw.
  defp refresh(component) do
    QuietJS.quiet()
    derived = derive(component, component.props.snapshot, component.props.strategy)

    component
    |> put_state(derived: derived, view: Plan.view(derived))
    |> draw(derived)
  end

  # The simulations depend only on the snapshot and the budget, so a cached
  # result for the same pair is reused (e.g. when just the strategy changed).
  defp derive(component, snapshot, strategy) do
    state = component.state
    mode = mode(state.mode_pending, snapshot)
    budget = Plan.effective_budget(snapshot, state.budget_draft, mode)

    case Map.get(state, :derived) do
      %{snapshot: ^snapshot, budget: ^budget} = cached -> %{cached | strategy: strategy}
      _stale_or_none -> Plan.derive(snapshot, strategy, budget, state.today)
    end
  end

  # Builds the selected chart and hands its config straight to the chart
  # component (the config is not kept in state: it can be large). This is
  # the handler's one follow-up action.
  defp draw(component, derived) do
    {message, config} = Plan.chart(derived, component.state.chart_type)
    component = put_state(component, :chart_message, message)

    case config do
      nil ->
        put_action(component, name: :clear, target: "plan_chart")

      config ->
        put_action(component, name: :draw, target: "plan_chart", params: %{config: config})
    end
  end

  # Drops the typed budget once it's no longer needed: the input isn't
  # focused and the text is either unparseable (revert to the saved value)
  # or already saved. While a save is in flight it stays, so the plan keeps
  # using it until the fresh snapshot arrives.
  defp settle_draft(%{state: %{budget_draft: nil}} = component), do: component
  defp settle_draft(%{state: %{budget_focused?: true}} = component), do: component

  defp settle_draft(component) do
    snapshot = component.props.snapshot
    mode = mode(component.state.mode_pending, snapshot)
    saved = snapshot.settings.monthly_budget

    case Plan.draft_total(snapshot, component.state.budget_draft, mode) do
      {:ok, cents} when cents != saved -> component
      _saved_or_invalid -> put_state(component, :budget_draft, nil)
    end
  end
end
