defmodule DebtReliefTrackerWeb.Holo.Components.LogAllBalancesModal do
  @moduledoc """
  Log-all-balances modal (modal type `:log_all_balances`, `modal.today`).
  Port of `DashboardLive`'s `log_all_balances_modal` / `save_log_all_balances`:
  one input per active debt, pre-filled with its estimated balance as of the
  server-supplied today; saving sends a `{:reconcile_balance, id, cents}`
  change for each non-blank entry.
  """

  use Hologram.Component

  alias DebtReliefTrackerWeb.Holo.Auth
  alias DebtReliefTrackerWeb.Holo.Components.DebtModalFrame
  alias DebtReliefTrackerWeb.Holo.DebtCommands
  alias DebtReliefTrackerWeb.Holo.DebtLogic
  alias DebtReliefTrackerWeb.Holo.Format

  middleware Auth

  prop :snapshot, :map
  prop :account, :map
  prop :modal, :map, default: nil

  def init(props, component), do: init_state(props, component)
  def init(props, component, _server), do: init_state(props, component)

  defp init_state(props, component) do
    today = (props.modal && Map.get(props.modal, :today)) || ""

    entries =
      for debt <- DebtLogic.active_debts(props.snapshot) do
        %{
          id: debt.id,
          name: debt.name,
          value: Format.cents_input(DebtLogic.estimated_balance(debt, today)),
          error: nil
        }
      end

    component
    |> put_state(:entries, entries)
    |> put_state(:error, nil)
  end

  def template do
    ~HOLO"""
    <DebtModalFrame id="log-all-balances-modal">
      <h2 id="log-all-balances-title" class="font-semibold text-lg mb-4">Log all balances</h2>
      <form id="log-all-balances-form" class="flex flex-col gap-2" $submit="save">
        {%for entry <- @entries}
          <div id={"balance-row-#{entry.id}"} class="flex flex-col sm:flex-row gap-1 sm:gap-2 sm:items-center">
            <label class="sm:w-40 text-sm truncate">{entry.name}</label>
            <div class="w-full sm:flex-1">
              <input
                id={"balance-#{entry.id}"}
                type="text"
                inputmode="decimal"
                class="input input-sm w-full"
                value={entry.value}
                $change={:set_balance, id: entry.id}
              />
              {%if entry.error}
                <p class="mt-1 text-sm text-error">{entry.error}</p>
              {/if}
            </div>
          </div>
        {/for}
        {%if @error}
          <p id="log-all-balances-error" class="text-sm text-error">{@error}</p>
        {/if}
        <div class="flex justify-end gap-2 mt-2">
          <button id="log-all-balances-cancel" type="button" class="btn" $click={action: :close_modal, target: "page"}>Cancel</button>
          <button id="log-all-balances-save" type="submit" class="btn btn-primary">Save balances</button>
        </div>
      </form>
    </DebtModalFrame>
    """
  end

  def action(:set_balance, %{id: id, event: %{value: value}}, component) do
    entries =
      Enum.map(component.state.entries, fn entry ->
        if entry.id == id, do: %{entry | value: value, error: nil}, else: entry
      end)

    put_state(component, :entries, entries)
  end

  def action(:save, _params, component) do
    values = Map.new(component.state.entries, &{&1.id, &1.value})

    case DebtLogic.balance_changes(component.props.snapshot, values) do
      {:ok, changes} ->
        component
        |> put_state(:error, nil)
        |> put_command(:save, changes: changes, notice: "Balances updated.")

      {:error, errors} ->
        entries =
          Enum.map(component.state.entries, fn entry ->
            %{entry | error: errors |> Map.get(entry.id, [nil]) |> List.first()}
          end)

        put_state(component, :entries, entries)
    end
  end

  def action(:save_failed, %{error: error}, component),
    do: put_state(component, :error, DebtLogic.error_text(error))

  def command(:save, %{changes: changes, notice: notice}, server),
    do: DebtCommands.run(server, changes, notice, close_modal: true)
end
