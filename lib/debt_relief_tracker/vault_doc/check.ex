defmodule DebtReliefTracker.VaultDoc.Check do
  @moduledoc """
  Cast and validation of change attributes, mirroring `Debt.changeset/2`,
  `Payment.changeset/2`, `Setting.changeset/2` and the `RetirementProfile`
  changesets as `Storage.Plain` surfaces them: an error map
  `%{changeset_field => [message]}` with the changesets' own field names
  (`:apr`, `:minimum_payment_rate`, `:post_debt_investment_pct`,
  `:expected_annual_return_pct`, ... even though the attrs use `_bp` keys) and
  the same messages. Client-safe.

  Every function returns `{:ok, values}` or `{:error, errors}`; none raises on
  any input. Unlike the Decimal path, attrs must already be in snapshot units
  (integers, ISO strings); anything else is `"is invalid"`.
  """

  alias DebtReliefTracker.VaultDoc.Stamp

  @type errors :: %{optional(atom() | String.t()) => [String.t()]}

  # {attr key, changeset field, cast type}
  @debt_spec [
    {:name, :name, :string},
    {:type, :type, {:enum, ["revolving", "installment"], nil}},
    {:balance, :balance, :int},
    {:original_balance, :original_balance, :int},
    {:apr_bp, :apr, :int},
    {:fixed_payment, :fixed_payment, :int},
    {:minimum_payment_floor, :minimum_payment_floor, :int},
    {:minimum_payment_rate_bp, :minimum_payment_rate, :int},
    {:credit_limit, :credit_limit, :int},
    {:exclude_from_plan, :exclude_from_plan, :bool},
    {:statement_balance, :statement_balance, :int},
    {:statement_date, :statement_date, :date},
    {:position, :position, :int},
    {:due_day, :due_day, :int},
    {:auto_log_mode, :auto_log_mode, {:enum, ["off", "confirm", "automatic"], "off"}},
    {:last_due_handled_on, :last_due_handled_on, :date}
  ]

  @payment_spec [
    {:amount, :amount, :int},
    {:principal_portion, :principal_portion, :int},
    {:interest_portion, :interest_portion, :int},
    {:paid_on, :paid_on, :date},
    {:note, :note, :string}
  ]

  @settings_spec [
    {:monthly_budget, :monthly_budget, :int},
    {:currency, :currency, {:string, "USD"}},
    {:budget_mode, :budget_mode, {:enum, ["total", "margin"], "total"}},
    {:retirement_onboarding_dismissed, :retirement_onboarding_dismissed, :bool}
  ]

  @profile_spec [
    {:name, :name, :string},
    {:claim_email, :claim_email, :string},
    {:current_age, :current_age, :int},
    {:retirement_age, :retirement_age, :int},
    {:current_retirement_savings, :current_retirement_savings, :int},
    {:monthly_retirement_contribution, :monthly_retirement_contribution, :int},
    {:monthly_gross_income, :monthly_gross_income, :int},
    {:post_debt_investment_bp, :post_debt_investment_pct, :int},
    {:expected_annual_return_bp, :expected_annual_return_pct, :int}
  ]

  @profile_numeric [
    :current_age,
    :retirement_age,
    :current_retirement_savings,
    :monthly_retirement_contribution,
    :monthly_gross_income,
    :post_debt_investment_bp,
    :expected_annual_return_bp
  ]

  # --- debts -----------------------------------------------------------------

  @doc "Snapshot-unit defaults of a new debt (before `attrs` are cast over them)."
  def debt_defaults do
    %{
      name: nil,
      type: nil,
      balance: nil,
      original_balance: nil,
      apr_bp: nil,
      fixed_payment: nil,
      minimum_payment_floor: nil,
      minimum_payment_rate_bp: nil,
      credit_limit: nil,
      exclude_from_plan: false,
      statement_balance: nil,
      statement_date: nil,
      position: 0,
      due_day: nil,
      auto_log_mode: "off",
      last_due_handled_on: nil
    }
  end

  @doc "The editable debt fields of `current` (a doc debt record or snapshot debt)."
  def debt_fields(current), do: Map.take(current, Map.keys(debt_defaults()))

  @doc """
  Casts and validates `attrs` over `current` (the editable fields of an
  existing debt, or `debt_defaults/0` for a new one). Returns the full
  candidate field map.
  """
  def debt(current, attrs) do
    with {:ok, attrs} <- attrs_map(attrs, @debt_spec),
         {values, errors} <- cast(current, attrs, @debt_spec) do
      errors =
        errors
        |> required(values, [
          {:name, :name},
          {:type, :type},
          {:balance, :balance},
          {:apr_bp, :apr}
        ])
        |> number(attrs, values, :balance, :balance, min: 0)
        |> number(attrs, values, :original_balance, :original_balance, min: 0)
        |> number(attrs, values, :apr_bp, :apr, min: 0)
        |> type_specific(values)
        |> auto_log(attrs, values)

      finish(values, errors)
    end
  end

  defp type_specific(errors, values) do
    case values.type do
      "revolving" -> required(errors, values, [{:minimum_payment_rate_bp, :minimum_payment_rate}])
      "installment" -> required(errors, values, [{:fixed_payment, :fixed_payment}])
      _ -> errors
    end
  end

  defp auto_log(errors, attrs, values) do
    if values.auto_log_mode in ["confirm", "automatic"] do
      errors
      |> then(fn errors ->
        if values.type == "installment",
          do: errors,
          else: add(errors, :auto_log_mode, "is only available for installment debts")
      end)
      |> required(values, [{:due_day, :due_day}])
      |> number(attrs, values, :due_day, :due_day, min: 1, max: 31)
    else
      errors
    end
  end

  # --- payments --------------------------------------------------------------

  @doc "Casts and validates payment attrs (`Payment.changeset/2` minus the debt id)."
  def payment(attrs) do
    base = %{
      amount: nil,
      principal_portion: nil,
      interest_portion: nil,
      paid_on: nil,
      note: nil
    }

    with {:ok, attrs} <- attrs_map(attrs, @payment_spec),
         {values, errors} <- cast(base, attrs, @payment_spec) do
      errors =
        errors
        |> required(values, [{:amount, :amount}, {:paid_on, :paid_on}])
        |> number(attrs, values, :amount, :amount, greater_than: 0)

      finish(values, errors)
    end
  end

  # --- settings --------------------------------------------------------------

  @doc "Casts and validates settings attrs over the `current` settings map."
  def settings(current, attrs) do
    with {:ok, attrs} <- attrs_map(attrs, @settings_spec),
         {values, errors} <- cast(current, attrs, @settings_spec) do
      finish(values, required(errors, values, [{:currency, :currency}]))
    end
  end

  # --- retirement profiles ---------------------------------------------------

  @doc """
  Profile attrs. `kind` is `:member` (a new profile linked to a member; `name`
  and `claim_email` are dropped), `:manual` (new, needs `name`), `:update_manual`
  or `:update_linked` (an update; a linked profile ignores `name`/`claim_email`).
  `current` is the existing profile's editable fields (all nil for a new one).
  """
  def profile(kind, current, attrs) do
    attrs =
      if kind == :member and is_map(attrs),
        do: Map.drop(attrs, [:name, :claim_email]),
        else: attrs

    with {:ok, attrs} <- attrs_map(attrs, @profile_spec),
         attrs =
           if(kind == :update_linked, do: Map.drop(attrs, [:name, :claim_email]), else: attrs),
         {values, errors} <- cast(current, attrs, @profile_spec) do
      errors =
        errors
        |> required(values, Enum.map(profile_required(kind), &{&1, field_for(&1)}))
        |> number(attrs, values, :current_age, :current_age, min: 0, max: 120)
        |> number(attrs, values, :retirement_age, :retirement_age, min: 1, max: 120)
        |> number(attrs, values, :current_retirement_savings, :current_retirement_savings, min: 0)
        |> number(
          attrs,
          values,
          :monthly_retirement_contribution,
          :monthly_retirement_contribution,
          min: 0
        )
        |> number(attrs, values, :monthly_gross_income, :monthly_gross_income, min: 0)
        |> number(attrs, values, :post_debt_investment_bp, :post_debt_investment_pct,
          min: 0,
          max: 10_000,
          shown_max: 100
        )
        |> number(attrs, values, :expected_annual_return_bp, :expected_annual_return_pct,
          min: 0,
          max: 3_000,
          shown_max: 30
        )
        |> retirement_after_current(values)

      finish(values, errors)
    end
  end

  defp profile_required(kind) do
    case kind do
      :manual -> [:name | @profile_numeric]
      :update_manual -> [:name | @profile_numeric]
      _ -> @profile_numeric
    end
  end

  defp field_for(key) do
    case Enum.find(@profile_spec, fn {k, _, _} -> k == key end) do
      {_, field, _} -> field
      nil -> key
    end
  end

  defp retirement_after_current(errors, values) do
    current = values.current_age
    retirement = values.retirement_age

    if is_integer(current) and is_integer(retirement) and retirement <= current do
      add(errors, :retirement_age, "must be greater than current age")
    else
      errors
    end
  end

  @doc "A blank profile (all editable fields nil)."
  def profile_defaults do
    %{name: nil, claim_email: nil}
    |> Map.merge(Map.new(@profile_numeric, &{&1, nil}))
  end

  @doc "The editable fields of an existing profile record."
  def profile_fields(record), do: Map.take(record, Map.keys(profile_defaults()))

  # --- machinery -------------------------------------------------------------

  @doc "Adds `message` under `field` (newest first, like `traverse_errors`)."
  def add(errors, field, message), do: Map.update(errors, field, [message], &[message | &1])

  defp finish(values, errors) when map_size(errors) == 0, do: {:ok, values}
  defp finish(_values, errors), do: {:error, errors}

  # Unknown keys are reported alone, like Storage.Plain's `convert/2`.
  defp attrs_map(attrs, spec) when is_map(attrs) and not is_struct(attrs) do
    allowed = Enum.map(spec, &elem(&1, 0))

    case Enum.reject(Map.keys(attrs), &(&1 in allowed)) do
      [] -> {:ok, attrs}
      unknown -> {:error, Map.new(unknown, &{&1, ["is not an allowed field"]})}
    end
  end

  defp attrs_map(_attrs, _spec), do: {:error, %{attrs: ["is invalid"]}}

  # -> {values, errors}
  defp cast(current, attrs, spec) do
    Enum.reduce(spec, {current, %{}}, fn {key, field, type}, {values, errors} ->
      case Map.fetch(attrs, key) do
        {:ok, raw} ->
          case cast_value(type, raw) do
            {:ok, value} -> {Map.put(values, key, value), errors}
            :error -> {values, add(errors, field, "is invalid")}
          end

        :error ->
          {values, errors}
      end
    end)
  end

  defp cast_value(_type, nil), do: {:ok, nil}

  # Ecto's cast turns an empty ("" / whitespace) string into the field's
  # schema default (nil when it has none), e.g. currency "" -> "USD".
  defp cast_value(:string, value), do: cast_value({:string, nil}, value)

  defp cast_value({:string, default}, value) when is_binary(value) do
    cond do
      not String.valid?(value) -> :error
      String.trim(value) == "" -> {:ok, default}
      true -> {:ok, value}
    end
  end

  defp cast_value(:int, value) when is_integer(value), do: {:ok, value}
  defp cast_value(:bool, value) when is_boolean(value), do: {:ok, value}

  defp cast_value({:enum, values, default}, value) when is_binary(value) do
    cond do
      value in values -> {:ok, value}
      String.trim(value) == "" -> {:ok, default}
      true -> :error
    end
  end

  defp cast_value(:date, value) when is_binary(value) do
    case Stamp.parse_date(value) do
      {:ok, ymd} -> {:ok, Stamp.format_date(ymd)}
      :error -> :error
    end
  end

  defp cast_value(_type, _value), do: :error

  # validate_required: nil value, and no earlier error on that field.
  defp required(errors, values, pairs) do
    Enum.reduce(pairs, errors, fn {key, field}, errors ->
      if Map.get(values, key) == nil and not Map.has_key?(errors, field),
        do: add(errors, field, "can't be blank"),
        else: errors
    end)
  end

  # validate_number: only for attrs that were given, non-nil, and not already invalid.
  defp number(errors, attrs, values, key, field, opts) do
    value = Map.get(values, key)

    if Map.has_key?(attrs, key) and is_integer(value) and not Map.has_key?(errors, field) do
      min = Keyword.get(opts, :min)
      max = Keyword.get(opts, :max)
      shown_max = Keyword.get(opts, :shown_max, max)

      cond do
        Keyword.has_key?(opts, :greater_than) and value <= Keyword.fetch!(opts, :greater_than) ->
          add(errors, field, "must be greater than #{Keyword.fetch!(opts, :greater_than)}")

        min != nil and value < min ->
          shown_min = Keyword.get(opts, :shown_min, min)
          add(errors, field, "must be greater than or equal to #{shown_min}")

        max != nil and value > max ->
          add(errors, field, "must be less than or equal to #{shown_max}")

        true ->
          errors
      end
    else
      errors
    end
  end
end
