defmodule DebtReliefTrackerWeb.Holo.DebtLogic do
  @moduledoc """
  Pure, client-safe logic behind the debt-management components (sidebar,
  add/edit debt, log payment, log all balances, due-payment prompts). Works on
  `Storage` snapshot maps and plain form-text maps; no Decimal/Date/regex, so
  it runs in the browser and in ExUnit.

  "Today" never comes from a clock here: callers pass an ISO date string that
  the server supplied (`Holo.Context.today_iso/0`, set in `DebtSidebar.init/3`
  and refreshed by its commands, then carried inside the `:modal` map).

  Form values are kept as the user's text. `*_change`/`*_attrs` functions
  validate (mirroring the `Debt`/`Payment` changesets so the common errors
  show without a round trip), convert dollars->cents / percent->basis points
  with integer string math, and return `{:ok, attrs}` for a `Storage` change
  or `{:error, %{field => [message]}}`.
  """

  alias DebtReliefTracker.Engine.Calculations
  alias DebtReliefTracker.Engine.Days
  alias DebtReliefTracker.Engine.DueSchedule
  alias DebtReliefTracker.Engine.FromSnapshot
  alias DebtReliefTrackerWeb.Holo.Format

  @blank "can't be blank"
  @invalid "is invalid"
  @negative "must be greater than or equal to 0"

  # --- lookups ----------------------------------------------------------------

  def find_debt(snapshot, id), do: Enum.find(snapshot.debts, &(&1.id == id))

  def active_debts(snapshot), do: Enum.filter(snapshot.debts, &(&1.status != "paid_off"))

  # --- sidebar rows -----------------------------------------------------------

  @doc "Estimated balance in cents as of the ISO date `today_iso`."
  def estimated_balance(debt, today_iso) do
    Calculations.estimated_balance(FromSnapshot.debt(debt), days(today_iso))
  end

  defp days(iso), do: Days.to_days(FromSnapshot.parse_date(iso))

  @doc "Display-ready rows for the sidebar's debt list."
  def rows(snapshot, today_iso) do
    currency = snapshot.settings.currency

    Enum.map(snapshot.debts, fn debt ->
      engine_debt = FromSnapshot.debt(debt)
      paid_off? = debt.status == "paid_off"
      revolving? = debt.type == "revolving"
      utilization = Calculations.credit_utilization_bp(engine_debt)

      %{
        id: debt.id,
        name: debt.name,
        type: debt.type,
        paid_off: paid_off?,
        revolving: revolving?,
        balance_text:
          Format.money(Calculations.estimated_balance(engine_debt, days(today_iso)), currency),
        utilization_text: utilization && "#{Format.percent_bp(utilization)} utilization",
        item_class:
          if(debt.exclude_from_plan,
            do: "rounded border border-base-300 p-2 opacity-50",
            else: "rounded border border-base-300 p-2"
          ),
        name_class:
          if(paid_off?,
            do: "font-medium text-sm truncate line-through opacity-60",
            else: "font-medium text-sm truncate"
          )
      }
    end)
  end

  # --- due-payment prompts ----------------------------------------------------

  @doc """
  Confirm-mode debts whose current cycle is unhandled (the LiveView's
  `due_prompts/1`; automatic-mode debts are handled elsewhere and don't nag).
  Each prompt carries the `cycle` (ISO date) the answer must name.
  """
  def due_prompts(snapshot, today_iso) do
    today = FromSnapshot.parse_date(today_iso)

    snapshot.debts
    |> Enum.filter(&(&1.auto_log_mode == "confirm"))
    |> Enum.flat_map(fn debt ->
      engine_debt = FromSnapshot.debt(debt)

      if DueSchedule.due?(engine_debt, today) do
        [
          %{
            id: debt.id,
            name: debt.name,
            fixed_payment: debt.fixed_payment,
            cycle: engine_debt |> DueSchedule.current_cycle_due_date(today) |> iso_date()
          }
        ]
      else
        []
      end
    end)
  end

  @doc "`{2026, 3, 5}` -> `\"2026-03-05\"`."
  def iso_date({year, month, day}), do: "#{year}-#{pad2(month)}-#{pad2(day)}"

  defp pad2(n) when n < 10, do: "0#{n}"
  defp pad2(n), do: "#{n}"

  # --- add / edit debt form ---------------------------------------------------

  @doc "Initial form text for a new debt (`nil`) or an existing snapshot debt."
  def debt_form(nil) do
    %{
      name: "",
      type: "",
      balance: "",
      original_balance: "",
      apr: "",
      minimum_payment_floor: "",
      minimum_payment_rate: "",
      credit_limit: "",
      fixed_payment: "",
      auto_log_mode: "off",
      due_day: "",
      exclude_from_plan: false
    }
  end

  def debt_form(debt) do
    %{
      name: debt.name,
      type: debt.type,
      balance: Format.cents_input(debt.balance),
      original_balance: Format.cents_input(debt.original_balance),
      apr: Format.to_plain(debt.apr_bp, 2),
      minimum_payment_floor: Format.cents_input(debt.minimum_payment_floor),
      minimum_payment_rate: Format.to_plain(debt.minimum_payment_rate_bp, 4, 2),
      credit_limit: Format.cents_input(debt.credit_limit),
      fixed_payment: Format.cents_input(debt.fixed_payment),
      auto_log_mode: debt.auto_log_mode,
      due_day: if(debt.due_day, do: Integer.to_string(debt.due_day), else: ""),
      exclude_from_plan: debt.exclude_from_plan
    }
  end

  @doc "Sets one form field from an input event value."
  def put_field(form, field, value), do: Map.put(form, field, value)

  @doc """
  Validates the debt form and builds the `Storage` attrs (`:add_debt` /
  `:update_debt`). Only fields shown for the chosen type are sent, like the
  LiveView form.
  """
  def debt_change(form) do
    {fields, errors} =
      {%{}, %{}}
      |> text_field(:name, form.name, true)
      |> enum_field(:type, form.type, ["revolving", "installment"])
      |> money_field(:balance, form.balance, true)
      |> money_field(:original_balance, form.original_balance, false)
      |> scaled_field(:apr_bp, :apr, form.apr, 2, true)
      |> type_fields(form)

    if errors == %{} do
      {:ok, Map.put(fields, :exclude_from_plan, form.exclude_from_plan == true)}
    else
      {:error, errors}
    end
  end

  defp type_fields(acc, %{type: "revolving"} = form) do
    acc
    |> money_field(:minimum_payment_floor, form.minimum_payment_floor, false)
    |> scaled_field(:minimum_payment_rate_bp, :minimum_payment_rate, form.minimum_payment_rate, 4, true)
    |> money_field(:credit_limit, form.credit_limit, false)
    |> put_plain(:auto_log_mode, "off")
  end

  defp type_fields(acc, %{type: "installment"} = form) do
    acc
    |> money_field(:fixed_payment, form.fixed_payment, true)
    |> enum_field(:auto_log_mode, form.auto_log_mode, ["off", "confirm", "automatic"])
    |> due_day_field(form)
  end

  defp type_fields(acc, _form), do: acc

  defp due_day_field(acc, %{auto_log_mode: "off"}), do: acc

  defp due_day_field({fields, errors}, form) do
    case String.trim(form.due_day) do
      "" ->
        {fields, add_error(errors, :due_day, @blank)}

      text ->
        case Format.parse_scaled(text, 0) do
          {:ok, n} when n >= 1 and n <= 31 -> {Map.put(fields, :due_day, n), errors}
          {:ok, _out_of_range} -> {fields, add_error(errors, :due_day, "must be between 1 and 31")}
          :error -> {fields, add_error(errors, :due_day, @invalid)}
        end
    end
  end

  defp text_field({fields, errors}, key, text, required?) do
    case String.trim(text) do
      "" when required? -> {fields, add_error(errors, key, @blank)}
      "" -> {Map.put(fields, key, nil), errors}
      trimmed -> {Map.put(fields, key, trimmed), errors}
    end
  end

  defp enum_field({fields, errors}, key, value, allowed) do
    cond do
      value == "" -> {fields, add_error(errors, key, @blank)}
      value in allowed -> {Map.put(fields, key, value), errors}
      true -> {fields, add_error(errors, key, @invalid)}
    end
  end

  defp put_plain({fields, errors}, key, value), do: {Map.put(fields, key, value), errors}

  defp money_field(acc, key, text, required?), do: scaled_field(acc, key, key, text, 2, required?)

  # `key` is the Storage attr, `error_key` the form field the message shows on.
  defp scaled_field({fields, errors}, key, error_key, text, scale, required?) do
    case Format.parse_scaled(text, scale) do
      {:ok, nil} when required? -> {fields, add_error(errors, error_key, @blank)}
      {:ok, nil} -> {Map.put(fields, key, nil), errors}
      {:ok, n} when n < 0 -> {fields, add_error(errors, error_key, @negative)}
      {:ok, n} -> {Map.put(fields, key, n), errors}
      :error -> {fields, add_error(errors, error_key, @invalid)}
    end
  end

  defp add_error(errors, key, message), do: Map.update(errors, key, [message], &(&1 ++ [message]))

  # --- log payment form ---------------------------------------------------------

  def payment_form(today_iso) do
    %{amount: "", principal_portion: "", interest_portion: "", paid_on: today_iso, note: ""}
  end

  @doc "Validates the payment form into `{:log_payment, ...}` attrs (cents)."
  def payment_attrs(form) do
    {fields, errors} =
      {%{}, %{}}
      |> money_field(:amount, form.amount, true)
      |> money_field(:principal_portion, form.principal_portion, false)
      |> money_field(:interest_portion, form.interest_portion, false)
      |> paid_on_field(form.paid_on)

    errors =
      cond do
        Map.has_key?(errors, :amount) -> errors
        Map.get(fields, :amount, 0) <= 0 -> add_error(errors, :amount, "must be greater than 0")
        true -> errors
      end

    if errors == %{} do
      note = String.trim(form.note)
      {:ok, Map.put(fields, :note, if(note == "", do: nil, else: note))}
    else
      {:error, errors}
    end
  end

  defp paid_on_field({fields, errors}, text) do
    if valid_iso_date?(text) do
      {Map.put(fields, :paid_on, text), errors}
    else
      key = :paid_on
      {fields, add_error(errors, key, if(text == "", do: @blank, else: @invalid))}
    end
  end

  @doc "True for a real calendar date written `YYYY-MM-DD`."
  def valid_iso_date?(text) when is_binary(text) do
    case String.split(text, "-") do
      [y, m, d] ->
        with true <- String.length(y) == 4 and String.length(m) == 2 and String.length(d) == 2,
              {:ok, year} <- Format.parse_scaled(y, 0),
             {:ok, month} <- Format.parse_scaled(m, 0),
             {:ok, day} <- Format.parse_scaled(d, 0) do
          is_integer(year) and is_integer(month) and is_integer(day) and month >= 1 and month <= 12 and
            day >= 1 and day <= Days.days_in_month(year, month)
        else
          _ -> false
        end

      _ ->
        false
    end
  end

  def valid_iso_date?(_other), do: false

  @doc "Error messages for one form field."
  def field_errors(errors, key), do: Map.get(errors, key, [])

  @doc "A `Storage` error -> the `%{field => [message]}` map the forms display."
  def error_map({:invalid, errors}), do: errors
  def error_map(:not_found), do: %{base: ["no longer exists"]}
  def error_map(:not_due), do: %{base: ["isn't due"]}
  def error_map(_other), do: %{base: ["could not be saved"]}

  @doc "A `Storage` error as one line of text."
  def error_text(error) do
    error |> error_map() |> other_errors([]) |> Enum.join(". ")
  end

  @doc "Messages for error keys the form has no field for (e.g. a negative resulting balance)."
  def other_errors(errors, known_keys) do
    for {key, messages} <- errors, key not in known_keys, message <- messages do
      "#{key} #{message}"
    end
  end

  # --- log all balances ---------------------------------------------------------

  @doc "`%{debt_id => text}` of each active debt's estimated balance."
  def balances_form(snapshot, today_iso) do
    snapshot
    |> active_debts()
    |> Map.new(fn debt -> {debt.id, Format.cents_input(estimated_balance(debt, today_iso))} end)
  end

  @doc """
  `{:ok, [{:reconcile_balance, id, cents}]}` for every non-blank entry
  (blank = leave that debt alone), else `{:error, %{debt_id => [message]}}`.
  """
  def balance_changes(snapshot, values) do
    results =
      for debt <- active_debts(snapshot) do
        case Format.parse_cents(Map.get(values, debt.id, "")) do
          {:ok, nil} -> :skip
          {:ok, cents} when cents < 0 -> {:error, debt.id, @negative}
          {:ok, cents} -> {:ok, {:reconcile_balance, debt.id, cents}}
          :error -> {:error, debt.id, @invalid}
        end
      end

    case for({:error, id, message} <- results, do: {id, [message]}) do
      [] -> {:ok, for({:ok, change} <- results, do: change)}
      errors -> {:error, Map.new(errors)}
    end
  end
end
