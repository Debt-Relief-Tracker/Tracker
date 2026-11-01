defmodule DebtReliefTracker.Storage.Plain do
  @moduledoc """
  `DebtReliefTracker.Storage` over today's tables. Each change is translated
  from snapshot units (cents, basis points) to the existing contexts' Decimal
  attrs and executed through them, so validation, balance updates and
  `ActivityLog` entries behave exactly as they do for the LiveView today.
  """

  @behaviour DebtReliefTracker.Storage

  alias DebtReliefTracker.Debts
  alias DebtReliefTracker.Debts.DueSchedule
  alias DebtReliefTracker.DuePayments
  alias DebtReliefTracker.Engine.Convert
  alias DebtReliefTracker.Payments
  alias DebtReliefTracker.Settings
  alias DebtReliefTracker.Storage.Snapshot

  @impl true
  def load(workspace), do: {:ok, Snapshot.build(workspace)}

  @impl true
  def apply_change(workspace, user, change) do
    with {:ok, _record} <- run(workspace, user, change) do
      {:ok, Snapshot.build(workspace)}
    end
  end

  defp run(workspace, user, {:add_debt, attrs}) do
    with {:ok, db_attrs} <- debt_attrs(attrs) do
      workspace |> Debts.create_debt(user, db_attrs) |> normalize()
    end
  end

  defp run(workspace, user, {:update_debt, id, attrs}) do
    with {:ok, debt} <- fetch_debt(workspace, id),
         {:ok, db_attrs} <- debt_attrs(attrs) do
      workspace |> Debts.update_debt(user, debt, db_attrs) |> normalize()
    end
  end

  defp run(workspace, user, {:mark_paid_off, id}) do
    with {:ok, debt} <- fetch_debt(workspace, id) do
      workspace |> Debts.mark_paid_off(user, debt) |> normalize()
    end
  end

  defp run(workspace, user, {:delete_debt, id}) do
    with {:ok, debt} <- fetch_debt(workspace, id) do
      workspace |> Debts.delete_debt(user, debt) |> normalize()
    end
  end

  defp run(workspace, user, {:log_payment, debt_id, attrs}) do
    with {:ok, debt} <- fetch_debt(workspace, debt_id),
         {:ok, db_attrs} <- payment_attrs(attrs) do
      workspace |> Payments.log_payment(user, debt, db_attrs) |> normalize()
    end
  end

  defp run(workspace, _user, {:update_settings, attrs}) do
    with {:ok, db_attrs} <- settings_attrs(attrs) do
      workspace |> Settings.get_settings!() |> Settings.update_settings(db_attrs) |> normalize()
    end
  end

  defp run(workspace, user, {:reconcile_balance, debt_id, new_balance}) when is_integer(new_balance) do
    with {:ok, debt} <- fetch_debt(workspace, debt_id) do
      workspace
      |> Debts.reconcile_balance(user, debt, Convert.from_cents(new_balance))
      |> normalize()
    end
  end

  defp run(workspace, user, {:handle_due, debt_id, action, cycle_iso})
       when action in [:post, :skip] do
    with {:ok, debt} <- fetch_debt(workspace, debt_id),
         {:ok, cycle} <- due_cycle(debt, cycle_iso) do
      # DuePayments derives the cycle from "today"; the cycle's own due date
      # is the one `today` for which that derivation returns it unchanged.
      result =
        case action do
          :post -> DuePayments.post_due_payment(workspace, user, debt, cycle)
          :skip -> DuePayments.skip_due_payment(workspace, user, debt, cycle)
        end

      normalize(result)
    end
  end

  # The client names the cycle it is answering; accept it only if it is a real
  # due date of this debt that has already come (never a future/made-up date).
  defp due_cycle(debt, cycle_iso) do
    with {:ok, cycle} <- Date.from_iso8601(cycle_iso),
         true <- Date.compare(cycle, Date.utc_today()) != :gt,
         true <- DueSchedule.current_cycle_due_date(debt, cycle) == cycle do
      {:ok, cycle}
    else
      _ -> {:error, :not_due}
    end
  end

  defp fetch_debt(workspace, id) do
    {:ok, Debts.get_debt!(workspace, id)}
  rescue
    # Unknown id, an id from another workspace, or a malformed UUID.
    Ecto.NoResultsError -> {:error, :not_found}
    Ecto.Query.CastError -> {:error, :not_found}
  end

  defp normalize({:ok, _} = ok), do: ok
  defp normalize({:error, :not_due} = error), do: error

  defp normalize({:error, %Ecto.Changeset{} = changeset}),
    do: {:error, {:invalid, errors(changeset)}}

  defp errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end

  # --- snapshot units -> context attrs ---------------------------------------

  @debt_cents %{
    balance: "balance",
    original_balance: "original_balance",
    fixed_payment: "fixed_payment",
    minimum_payment_floor: "minimum_payment_floor",
    credit_limit: "credit_limit",
    statement_balance: "statement_balance"
  }
  @debt_passthrough ~w(name type exclude_from_plan statement_date position due_day auto_log_mode last_due_handled_on)a

  defp debt_attrs(attrs) do
    convert(attrs, fn
      {key, value} when is_map_key(@debt_cents, key) ->
        {:ok, {Map.fetch!(@debt_cents, key), value && Convert.from_cents(value)}}

      {:apr_bp, value} ->
        {:ok, {"apr", value && Convert.bp_to_percent(value)}}

      {:minimum_payment_rate_bp, value} ->
        {:ok, {"minimum_payment_rate", value && Convert.bp_to_fraction(value)}}

      {key, value} when key in @debt_passthrough ->
        {:ok, {to_string(key), value}}

      {key, _value} ->
        {:error, key}
    end)
  end

  defp payment_attrs(attrs) do
    convert(attrs, fn
      {key, value} when key in [:amount, :principal_portion, :interest_portion] ->
        {:ok, {to_string(key), value && Convert.from_cents(value)}}

      {:paid_on, value} ->
        {:ok, {"paid_on", value}}

      {:note, value} ->
        {:ok, {"note", value}}

      {key, _value} ->
        {:error, key}
    end)
  end

  defp settings_attrs(attrs) do
    convert(attrs, fn
      {:monthly_budget, value} ->
        {:ok, {"monthly_budget", value && Convert.from_cents(value)}}

      {key, value} when key in [:currency, :budget_mode, :retirement_onboarding_dismissed] ->
        {:ok, {to_string(key), value}}

      {key, _value} ->
        {:error, key}
    end)
  end

  # Translates every attr or reports all the unknown keys at once.
  defp convert(attrs, fun) do
    results = Enum.map(attrs, fun)

    case for({:error, key} <- results, do: key) do
      [] -> {:ok, Map.new(for {:ok, pair} <- results, do: pair)}
      unknown -> {:error, {:invalid, Map.new(unknown, &{&1, ["is not an allowed field"]})}}
    end
  end
end
