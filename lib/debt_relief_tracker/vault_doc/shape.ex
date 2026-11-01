defmodule DebtReliefTracker.VaultDoc.Shape do
  @moduledoc """
  The field tables of the vault document: which keys each record kind has,
  their types, and strict conversion of decoded JSON (string keys) into
  records (atom keys). Unknown keys are dropped; missing or ill-typed keys
  make the whole document invalid. Client-safe.
  """

  alias DebtReliefTracker.VaultDoc.Stamp

  @debt_enums_type ["revolving", "installment"]
  @activity_actions [
    "debt_added",
    "debt_updated",
    "debt_paid_off",
    "debt_deleted",
    "payment_logged",
    "payment_auto_logged",
    "due_payment_skipped"
  ]

  @debt [
    id: :id,
    name: :str,
    type: {:enum, @debt_enums_type},
    status: {:enum, ["active", "paid_off"]},
    balance: :int,
    original_balance: :int?,
    apr_bp: :int,
    fixed_payment: :int?,
    minimum_payment_floor: :int?,
    minimum_payment_rate_bp: :int?,
    credit_limit: :int?,
    exclude_from_plan: :bool,
    statement_balance: :int?,
    statement_date: :date?,
    position: :int,
    due_day: :int?,
    auto_log_mode: {:enum, ["off", "confirm", "automatic"]},
    last_due_handled_on: :date?,
    paid_off_at: :str?,
    updated_at: :stamp,
    inserted_at: :stamp,
    deleted: :bool,
    applied: :applied
  ]

  @payment [
    id: :id,
    debt_id: :id,
    amount: :int,
    principal_portion: :int?,
    interest_portion: :int?,
    paid_on: :date,
    note: :str?,
    logged_by_user_id: :str?,
    inserted_at: :stamp,
    updated_at: :stamp,
    deleted: :bool
  ]

  @activity [
    id: :id,
    action: {:enum, @activity_actions},
    debt_id: :str?,
    user_id: :str?,
    metadata: :map,
    inserted_at: :stamp,
    updated_at: :stamp,
    deleted: :bool
  ]

  @retirement [
    id: :id,
    user_id: :str?,
    display_name: :str?,
    name: :str?,
    claim_email: :str?,
    current_age: :int,
    retirement_age: :int,
    current_retirement_savings: :int,
    monthly_retirement_contribution: :int,
    monthly_gross_income: :int,
    post_debt_investment_bp: :int,
    expected_annual_return_bp: :int,
    inserted_at: :stamp,
    updated_at: :stamp,
    deleted: :bool
  ]

  @settings [
    monthly_budget: :int?,
    currency: :str,
    budget_mode: {:enum, ["total", "margin"]},
    retirement_onboarding_dismissed: :bool
  ]

  @settings_keys [:monthly_budget, :currency, :budget_mode, :retirement_onboarding_dismissed]

  def settings_keys, do: @settings_keys
  def activity_actions, do: @activity_actions

  @doc "Field names of a record kind, in table order."
  def fields(kind), do: Enum.map(spec(kind), &elem(&1, 0))

  defp spec(:debt), do: @debt
  defp spec(:payment), do: @payment
  defp spec(:activity), do: @activity
  defp spec(:retirement), do: @retirement
  defp spec(:settings), do: @settings

  @doc "Converts a decoded JSON object into a record of `kind`, or `:error`."
  def record(kind, map) when is_map(map) do
    Enum.reduce_while(spec(kind), {:ok, %{}}, fn {field, type}, {:ok, acc} ->
      case convert(type, Map.get(map, Atom.to_string(field))) do
        {:ok, value} -> {:cont, {:ok, Map.put(acc, field, value)}}
        :error -> {:halt, :error}
      end
    end)
  end

  def record(_kind, _other), do: :error

  @doc "A map of `id => record` of `kind`; every key must equal its record's id."
  def records(kind, map) when is_map(map) do
    Enum.reduce_while(map, {:ok, %{}}, fn {key, raw}, {:ok, acc} ->
      case record(kind, raw) do
        {:ok, %{id: ^key} = rec} -> {:cont, {:ok, Map.put(acc, key, rec)}}
        _ -> {:halt, :error}
      end
    end)
  end

  def records(_kind, _other), do: :error

  @doc "Settings object + its per-key stamps."
  def settings(settings, stamps) when is_map(settings) and is_map(stamps) do
    with {:ok, settings} <- record(:settings, settings) do
      stamps =
        Enum.reduce_while(@settings_keys, {:ok, %{}}, fn key, {:ok, acc} ->
          case convert(:stamp, Map.get(stamps, Atom.to_string(key))) do
            {:ok, stamp} -> {:cont, {:ok, Map.put(acc, key, stamp)}}
            :error -> {:halt, :error}
          end
        end)

      with {:ok, stamps} <- stamps, do: {:ok, settings, stamps}
    end
  end

  def settings(_settings, _stamps), do: :error

  defp convert(:id, v) when is_binary(v) and v != "" and byte_size(v) <= 200, do: {:ok, v}
  defp convert(:str, v) when is_binary(v), do: {:ok, v}
  defp convert(:str?, v) when is_binary(v) or is_nil(v), do: {:ok, v}
  defp convert(:int, v) when is_integer(v), do: {:ok, v}
  defp convert(:int?, v) when is_integer(v) or is_nil(v), do: {:ok, v}
  defp convert(:bool, v) when is_boolean(v), do: {:ok, v}
  defp convert(:map, v) when is_map(v), do: {:ok, v}
  defp convert(:date?, nil), do: {:ok, nil}

  defp convert(:date?, v) when is_binary(v) do
    case Stamp.parse_date(v) do
      {:ok, _} -> {:ok, v}
      :error -> :error
    end
  end

  defp convert(:date, v) when is_binary(v), do: convert(:date?, v)
  defp convert(:stamp, v) when is_binary(v), do: if(Stamp.valid?(v), do: {:ok, v}, else: :error)
  defp convert({:enum, values}, v) when is_binary(v), do: if(v in values, do: {:ok, v}, else: :error)

  defp convert(:applied, v) when is_map(v) do
    if Enum.all?(v, fn {k, n} -> is_binary(k) and is_integer(n) end), do: {:ok, v}, else: :error
  end

  defp convert(_type, _value), do: :error
end
