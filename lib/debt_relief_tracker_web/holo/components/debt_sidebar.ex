defmodule DebtReliefTrackerWeb.Holo.Components.DebtSidebar do
  @moduledoc """
  Left rail: add-debt / log-all-balances / activity-log buttons, the debt
  list (est. balance, utilization, per-debt actions) and the confirm-mode
  due-payment prompts. Port of `DashboardLive`'s aside plus `due_prompts/1`,
  `mark_paid`, `confirm_due_payment` and `skip_due_payment`.

  ## "Today"

  Hologram has no `Date`, so the server supplies today's ISO date: `init/3`
  puts it in the `:today` state, and every command reply (`:synced`) refreshes
  it. Opening a modal copies it into the modal map (`modal.today`), which is
  how the payment / log-all-balances modals get a default date and estimated
  balances without any page-state addition.

  ## Notices

  The LiveView's flash messages become `:notice` / `:error` state shown at the
  top of the rail. Other debt components send their command result to this
  component's `:synced` action (see `Holo.DebtCommands`), which relays the
  snapshot to the page.
  """

  use Hologram.Component

  alias DebtReliefTrackerWeb.Holo.Auth
  alias DebtReliefTrackerWeb.Holo.Context
  alias DebtReliefTrackerWeb.Holo.DebtCommands
  alias DebtReliefTrackerWeb.Holo.DebtLogic
  alias DebtReliefTrackerWeb.Holo.Format

  middleware Auth

  prop :snapshot, :map
  prop :account, :map

  def init(_props, component, _server) do
    put_state(component,
      today: Context.today_iso(),
      list_open: false,
      confirm_paid_id: nil,
      notice: nil,
      error: nil
    )
  end

  def template do
    ~HOLO"""
    <div id="debt-sidebar" class="flex flex-col gap-3">
      <button id="add-debt-button" type="button" class="btn btn-primary btn-sm w-full" $click="open_add_debt">
        <span class="hero-plus size-4"></span> Add debt
      </button>
      <button id="log-all-balances-button" type="button" class="btn btn-soft btn-sm w-full" $click="open_log_all_balances">
        Log all balances
      </button>
      <button id="activity-log-button" type="button" class="btn btn-soft btn-sm w-full" $click="open_activity_log">
        Activity log
      </button>

      {%if @notice}
        <div id="debt-sidebar-notice" class="alert alert-success text-sm p-2 flex justify-between" $click="dismiss">
          <span>{@notice}</span>
        </div>
      {/if}
      {%if @error}
        <div id="debt-sidebar-error" class="alert alert-error text-sm p-2 flex justify-between" $click="dismiss">
          <span>{@error}</span>
        </div>
      {/if}

      {%for prompt <- DebtLogic.due_prompts(@snapshot, @today)}
        <div id={"due-prompt-#{prompt.id}"} class="alert alert-warning flex flex-col items-start gap-2 text-sm">
          <span>{prompt.name} payment ({Format.money(prompt.fixed_payment, @snapshot.settings.currency)}) is due.</span>
          <div class="flex gap-2">
            <button
              id={"confirm-due-payment-#{prompt.id}"}
              type="button"
              class="btn btn-primary btn-xs"
              $click={:due_decision, id: prompt.id, decision: :post, cycle: prompt.cycle}
            >
              Log it
            </button>
            <button
              id={"skip-due-payment-#{prompt.id}"}
              type="button"
              class="btn btn-xs"
              $click={:due_decision, id: prompt.id, decision: :skip, cycle: prompt.cycle}
            >
              Skip this month
            </button>
          </div>
        </div>
      {/for}

      <button
        id="debt-list-toggle"
        type="button"
        class="sm:hidden flex items-center justify-between w-full text-sm font-medium mt-2 cursor-pointer"
        $click="toggle_list"
      >
        <span>Debts ({length(@snapshot.debts)})</span>
        {%if @list_open}
          <span class="hero-chevron-up size-4"></span>
        {%else}
          <span class="hero-chevron-down size-4"></span>
        {/if}
      </button>

      <ul
        id="debt-list"
        class={list_class(@list_open)}
      >
        {%for row <- DebtLogic.rows(@snapshot, @today)}
          <li id={"debt-#{row.id}"} class={row.item_class}>
            <div class="flex items-center justify-between gap-1">
              <span class={row.name_class}>{row.name}</span>
              <span class="text-xs opacity-70">{row.type}</span>
            </div>
            <div class="text-sm">
              {row.balance_text}
              {%if row.revolving}
                <span class="text-xs opacity-60">est.</span>
              {/if}
            </div>
            {%if row.utilization_text}
              <div class="text-xs opacity-70">{row.utilization_text}</div>
            {/if}
            <div class="flex flex-wrap gap-1 mt-1">
              {%if not row.paid_off}
                <button id={"log-payment-#{row.id}"} type="button" class="btn btn-ghost btn-xs" $click={:open_log_payment, id: row.id}>
                  Log payment
                </button>
              {/if}
              <button id={"edit-debt-#{row.id}"} type="button" class="btn btn-ghost btn-xs" $click={:open_edit_debt, id: row.id}>
                Edit
              </button>
              {%if not row.paid_off}
                <button id={"mark-paid-#{row.id}"} type="button" class="btn btn-ghost btn-xs" $click={:ask_mark_paid, id: row.id}>
                  Mark paid
                </button>
              {/if}
            </div>
            {%if @confirm_paid_id == row.id}
              <div id={"confirm-paid-#{row.id}"} class="mt-1 text-xs flex flex-col gap-1">
                <span>Mark {row.name} as paid off?</span>
                <div class="flex gap-1">
                  <button id={"confirm-mark-paid-#{row.id}"} type="button" class="btn btn-primary btn-xs" $click={:mark_paid, id: row.id}>
                    Yes, mark paid
                  </button>
                  <button type="button" class="btn btn-xs" $click="cancel_mark_paid">Cancel</button>
                </div>
              </div>
            {/if}
          </li>
        {/for}
      </ul>
    </div>
    """
  end

  # Mobile: the list is collapsed behind the toggle; desktop (sm:) always shows it.
  def list_class(true), do: "flex flex-col gap-2 mt-2 sm:flex-1 sm:min-h-0 sm:overflow-y-auto"

  def list_class(false),
    do: "hidden flex-col gap-2 mt-2 sm:flex sm:flex-1 sm:min-h-0 sm:overflow-y-auto"

  # --- opening modals (a modal is a page action; see docs/holo-ui-conventions.md) ---

  def action(:open_add_debt, _params, component),
    do: open_modal(component, %{type: :add_debt, today: component.state.today})

  def action(:open_edit_debt, %{id: id}, component),
    do: open_modal(component, %{type: :edit_debt, debt_id: id, today: component.state.today})

  def action(:open_log_payment, %{id: id}, component),
    do: open_modal(component, %{type: :log_payment, debt_id: id, today: component.state.today})

  def action(:open_log_all_balances, _params, component),
    do: open_modal(component, %{type: :log_all_balances, today: component.state.today})

  def action(:open_activity_log, _params, component),
    do: open_modal(component, %{type: :activity_log})

  # --- local UI state ----------------------------------------------------------

  def action(:toggle_list, _params, component),
    do: put_state(component, :list_open, not component.state.list_open)

  def action(:ask_mark_paid, %{id: id}, component), do: put_state(component, :confirm_paid_id, id)

  def action(:cancel_mark_paid, _params, component),
    do: put_state(component, :confirm_paid_id, nil)

  def action(:dismiss, _params, component),
    do: component |> put_state(:notice, nil) |> put_state(:error, nil)

  # --- changes (-> command -> :synced / :failed) ---------------------------------

  def action(:mark_paid, %{id: id}, component) do
    name = debt_name(component, id)

    component
    |> put_state(:confirm_paid_id, nil)
    |> put_command(:apply, changes: [{:mark_paid_off, id}], notice: "#{name} marked as paid off.")
  end

  def action(:due_decision, %{id: id, decision: decision, cycle: cycle}, component) do
    name = debt_name(component, id)

    notice =
      case decision do
        :post -> "Logged #{name}'s payment."
        :skip -> "Skipped #{name} this month."
      end

    put_command(component, :apply, changes: [{:handle_due, id, decision, cycle}], notice: notice)
  end

  # Result of any debt command (this component's or a modal's): remember the
  # server's "today", show the notice, and hand the snapshot to the page
  # (closing its modal when the command came from one).
  def action(:synced, %{snapshot: snapshot} = params, component) do
    component
    |> put_state(:today, params.today)
    |> put_state(:notice, params.notice)
    |> put_state(:error, nil)
    |> put_action(
      name: :snapshot_updated,
      target: "page",
      params: %{snapshot: snapshot, close_modal: params.close_modal}
    )
  end

  def action(:failed, %{error: error}, component) do
    component
    |> put_state(:notice, nil)
    |> put_state(:error, DebtLogic.error_text(error))
  end

  def command(:apply, %{changes: changes, notice: notice}, server),
    do: DebtCommands.run(server, changes, notice, failure_action: :failed)

  defp open_modal(component, modal) do
    component
    |> put_state(:notice, nil)
    |> put_state(:error, nil)
    |> put_action(name: :open_modal, target: "page", params: %{modal: modal})
  end

  defp debt_name(component, id) do
    case DebtLogic.find_debt(component.props.snapshot, id) do
      nil -> "Debt"
      debt -> debt.name
    end
  end
end
