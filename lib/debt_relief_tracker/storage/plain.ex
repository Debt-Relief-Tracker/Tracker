defmodule DebtReliefTracker.Storage.Plain do
  @moduledoc """
  `DebtReliefTracker.Storage` over today's tables. Each change is translated
  from snapshot units (cents, basis points) to the existing contexts' Decimal
  attrs and executed through them, so validation, balance updates and
  `ActivityLog` entries behave exactly as they do for the LiveView today.
  """

  @behaviour DebtReliefTracker.Storage

  alias DebtReliefTracker.Accounts
  alias DebtReliefTracker.Debts
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

  defp run(workspace, _user, {:add_member_retirement_profile, user_id, attrs}) do
    with {:ok, member} <- fetch_member(workspace, user_id),
         {:ok, db_attrs} <- profile_attrs(attrs, [:name, :claim_email]) do
      workspace |> Settings.add_member_retirement_profile(member, db_attrs) |> normalize()
    end
  end

  defp run(workspace, _user, {:add_manual_retirement_profile, attrs}) do
    with {:ok, db_attrs} <- profile_attrs(attrs, []) do
      workspace |> Settings.add_manual_retirement_profile(db_attrs) |> normalize()
    end
  end

  defp run(workspace, _user, {:update_retirement_profile, id, attrs}) do
    with {:ok, profile} <- fetch_profile(workspace, id),
         {:ok, db_attrs} <- profile_attrs(attrs, []) do
      profile |> Settings.update_retirement_profile(db_attrs) |> normalize()
    end
  end

  defp run(workspace, _user, {:delete_retirement_profile, id}) do
    with {:ok, profile} <- fetch_profile(workspace, id) do
      profile |> Settings.delete_retirement_profile() |> normalize()
    end
  end

  defp fetch_profile(workspace, id) do
    case Enum.find(Settings.list_retirement_profiles(workspace), &(&1.id == id)) do
      nil -> {:error, :not_found}
      profile -> {:ok, profile}
    end
  end

  # Only confirmed members (owner included) can have a linked profile.
  defp fetch_member(workspace, user_id) do
    case Enum.find(Accounts.list_confirmed_members(workspace), &(&1.user_id == user_id)) do
      nil -> {:error, :not_found}
      member -> {:ok, member.user}
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

  @profile_cents ~w(current_retirement_savings monthly_retirement_contribution monthly_gross_income)a
  @profile_passthrough ~w(name claim_email current_age retirement_age)a

  # `rejected` keys are accepted but dropped (e.g. a member profile has no own
  # name/email, and the changeset would ignore them anyway).
  defp profile_attrs(attrs, rejected) do
    attrs = Map.drop(attrs, rejected)

    convert(attrs, fn
      {key, value} when key in @profile_cents ->
        {:ok, {to_string(key), value && Convert.from_cents(value)}}

      {:post_debt_investment_bp, value} ->
        {:ok, {"post_debt_investment_pct", value && Convert.bp_to_percent(value)}}

      {:expected_annual_return_bp, value} ->
        {:ok, {"expected_annual_return_pct", value && Convert.bp_to_percent(value)}}

      {key, value} when key in @profile_passthrough ->
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
