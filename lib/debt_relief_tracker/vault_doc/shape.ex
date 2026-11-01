defmodule DebtReliefTracker.VaultDoc.Shape do
  @moduledoc """
  Strict conversion of decoded JSON (string keys) into document records
  (atom keys). Each record kind is one function head with a map pattern and
  guards: unknown keys are dropped; a missing or ill-typed key makes the whole
  document invalid. Written as a single match per record because per-field
  helper calls cost ~100 us each in Hologram's interpreter (a 3000-record
  document spent seconds in them).

  Checks types and sizes (ids non-empty <= 200 bytes, stamps 27 bytes, dates
  10 bytes, enums from their value sets, integers), not calendar validity of
  stamps and dates: documents are authenticated ciphertext produced by this
  code. Client-safe.
  """

  @activity_actions [
    "debt_added",
    "debt_updated",
    "debt_paid_off",
    "debt_deleted",
    "payment_logged",
    "payment_auto_logged",
    "due_payment_skipped"
  ]

  @settings_keys [:monthly_budget, :currency, :budget_mode, :retirement_onboarding_dismissed]

  def settings_keys, do: @settings_keys
  def activity_actions, do: @activity_actions

  @doc "Converts a decoded JSON object into a record of `kind`, or `:error`."
  def record(:debt, %{
        "id" => id,
        "name" => name,
        "type" => type,
        "status" => status,
        "balance" => balance,
        "original_balance" => original_balance,
        "apr_bp" => apr_bp,
        "fixed_payment" => fixed_payment,
        "minimum_payment_floor" => minimum_payment_floor,
        "minimum_payment_rate_bp" => minimum_payment_rate_bp,
        "credit_limit" => credit_limit,
        "exclude_from_plan" => exclude_from_plan,
        "statement_balance" => statement_balance,
        "statement_date" => statement_date,
        "position" => position,
        "due_day" => due_day,
        "auto_log_mode" => auto_log_mode,
        "last_due_handled_on" => last_due_handled_on,
        "paid_off_at" => paid_off_at,
        "updated_at" => updated_at,
        "inserted_at" => inserted_at,
        "deleted" => deleted,
        "applied" => applied
      })
      when is_binary(id) and id != "" and byte_size(id) <= 200 and is_binary(name) and
             type in ["revolving", "installment"] and status in ["active", "paid_off"] and
             is_integer(balance) and (is_integer(original_balance) or is_nil(original_balance)) and
             is_integer(apr_bp) and (is_integer(fixed_payment) or is_nil(fixed_payment)) and
             (is_integer(minimum_payment_floor) or is_nil(minimum_payment_floor)) and
             (is_integer(minimum_payment_rate_bp) or is_nil(minimum_payment_rate_bp)) and
             (is_integer(credit_limit) or is_nil(credit_limit)) and is_boolean(exclude_from_plan) and
             (is_integer(statement_balance) or is_nil(statement_balance)) and
             (is_nil(statement_date) or
                (is_binary(statement_date) and byte_size(statement_date) == 10)) and
             is_integer(position) and (is_integer(due_day) or is_nil(due_day)) and
             auto_log_mode in ["off", "confirm", "automatic"] and
             (is_nil(last_due_handled_on) or
                (is_binary(last_due_handled_on) and byte_size(last_due_handled_on) == 10)) and
             (is_nil(paid_off_at) or is_binary(paid_off_at)) and
             is_binary(updated_at) and byte_size(updated_at) == 27 and is_binary(inserted_at) and
             byte_size(inserted_at) == 27 and is_boolean(deleted) and is_map(applied) do
    if :lists.all(&is_integer/1, Map.values(applied)) do
      {:ok,
       %{
         id: id,
         name: name,
         type: type,
         status: status,
         balance: balance,
         original_balance: original_balance,
         apr_bp: apr_bp,
         fixed_payment: fixed_payment,
         minimum_payment_floor: minimum_payment_floor,
         minimum_payment_rate_bp: minimum_payment_rate_bp,
         credit_limit: credit_limit,
         exclude_from_plan: exclude_from_plan,
         statement_balance: statement_balance,
         statement_date: statement_date,
         position: position,
         due_day: due_day,
         auto_log_mode: auto_log_mode,
         last_due_handled_on: last_due_handled_on,
         paid_off_at: paid_off_at,
         updated_at: updated_at,
         inserted_at: inserted_at,
         deleted: deleted,
         applied: applied
       }}
    else
      :error
    end
  end

  def record(:payment, %{
        "id" => id,
        "debt_id" => debt_id,
        "amount" => amount,
        "principal_portion" => principal_portion,
        "interest_portion" => interest_portion,
        "paid_on" => paid_on,
        "note" => note,
        "logged_by_user_id" => logged_by_user_id,
        "inserted_at" => inserted_at,
        "updated_at" => updated_at,
        "deleted" => deleted
      })
      when is_binary(id) and id != "" and byte_size(id) <= 200 and is_binary(debt_id) and
             debt_id != "" and byte_size(debt_id) <= 200 and is_integer(amount) and
             (is_integer(principal_portion) or is_nil(principal_portion)) and
             (is_integer(interest_portion) or is_nil(interest_portion)) and is_binary(paid_on) and
             byte_size(paid_on) == 10 and (is_binary(note) or is_nil(note)) and
             (is_binary(logged_by_user_id) or is_nil(logged_by_user_id)) and
             is_binary(inserted_at) and
             byte_size(inserted_at) == 27 and is_binary(updated_at) and
             byte_size(updated_at) == 27 and
             is_boolean(deleted) do
    {:ok,
     %{
       id: id,
       debt_id: debt_id,
       amount: amount,
       principal_portion: principal_portion,
       interest_portion: interest_portion,
       paid_on: paid_on,
       note: note,
       logged_by_user_id: logged_by_user_id,
       inserted_at: inserted_at,
       updated_at: updated_at,
       deleted: deleted
     }}
  end

  def record(:activity, %{
        "id" => id,
        "action" => action,
        "debt_id" => debt_id,
        "user_id" => user_id,
        "metadata" => metadata,
        "inserted_at" => inserted_at,
        "updated_at" => updated_at,
        "deleted" => deleted
      })
      when is_binary(id) and id != "" and byte_size(id) <= 200 and
             action in [
               "debt_added",
               "debt_updated",
               "debt_paid_off",
               "debt_deleted",
               "payment_logged",
               "payment_auto_logged",
               "due_payment_skipped"
             ] and (is_binary(debt_id) or is_nil(debt_id)) and
             (is_binary(user_id) or is_nil(user_id)) and is_map(metadata) and
             is_binary(inserted_at) and
             byte_size(inserted_at) == 27 and is_binary(updated_at) and
             byte_size(updated_at) == 27 and
             is_boolean(deleted) do
    {:ok,
     %{
       id: id,
       action: action,
       debt_id: debt_id,
       user_id: user_id,
       metadata: metadata,
       inserted_at: inserted_at,
       updated_at: updated_at,
       deleted: deleted
     }}
  end

  def record(:retirement, %{
        "id" => id,
        "user_id" => user_id,
        "display_name" => display_name,
        "name" => name,
        "claim_email" => claim_email,
        "current_age" => current_age,
        "retirement_age" => retirement_age,
        "current_retirement_savings" => current_retirement_savings,
        "monthly_retirement_contribution" => monthly_retirement_contribution,
        "monthly_gross_income" => monthly_gross_income,
        "post_debt_investment_bp" => post_debt_investment_bp,
        "expected_annual_return_bp" => expected_annual_return_bp,
        "inserted_at" => inserted_at,
        "updated_at" => updated_at,
        "deleted" => deleted
      })
      when is_binary(id) and id != "" and byte_size(id) <= 200 and
             (is_binary(user_id) or is_nil(user_id)) and
             (is_binary(display_name) or is_nil(display_name)) and
             (is_binary(name) or is_nil(name)) and
             (is_binary(claim_email) or is_nil(claim_email)) and is_integer(current_age) and
             is_integer(retirement_age) and is_integer(current_retirement_savings) and
             is_integer(monthly_retirement_contribution) and is_integer(monthly_gross_income) and
             is_integer(post_debt_investment_bp) and is_integer(expected_annual_return_bp) and
             is_binary(inserted_at) and byte_size(inserted_at) == 27 and is_binary(updated_at) and
             byte_size(updated_at) == 27 and is_boolean(deleted) do
    {:ok,
     %{
       id: id,
       user_id: user_id,
       display_name: display_name,
       name: name,
       claim_email: claim_email,
       current_age: current_age,
       retirement_age: retirement_age,
       current_retirement_savings: current_retirement_savings,
       monthly_retirement_contribution: monthly_retirement_contribution,
       monthly_gross_income: monthly_gross_income,
       post_debt_investment_bp: post_debt_investment_bp,
       expected_annual_return_bp: expected_annual_return_bp,
       inserted_at: inserted_at,
       updated_at: updated_at,
       deleted: deleted
     }}
  end

  def record(:settings, %{
        "monthly_budget" => monthly_budget,
        "currency" => currency,
        "budget_mode" => budget_mode,
        "retirement_onboarding_dismissed" => dismissed
      })
      when (is_integer(monthly_budget) or is_nil(monthly_budget)) and is_binary(currency) and
             budget_mode in ["total", "margin"] and is_boolean(dismissed) do
    {:ok,
     %{
       monthly_budget: monthly_budget,
       currency: currency,
       budget_mode: budget_mode,
       retirement_onboarding_dismissed: dismissed
     }}
  end

  def record(_kind, _other), do: :error

  @doc "A map of `id => record` of `kind`; every key must equal its record's id."
  def records(kind, map) when is_map(map) do
    # `for` + `Map.new` (linear in the browser; reduce + Map.put is not).
    results =
      for {key, raw} <- map do
        case record(kind, raw) do
          {:ok, %{id: ^key} = rec} -> {:ok, {key, rec}}
          _ -> :error
        end
      end

    if :lists.member(:error, results),
      do: :error,
      else: {:ok, Map.new(for({:ok, pair} <- results, do: pair))}
  end

  def records(_kind, _other), do: :error

  @doc "Settings object + its per-key stamps."
  def settings(settings, stamps) when is_map(settings) and is_map(stamps) do
    with {:ok, settings} <- record(:settings, settings),
         %{
           "monthly_budget" => a,
           "currency" => b,
           "budget_mode" => c,
           "retirement_onboarding_dismissed" => d
         } <- stamps,
         true <- Enum.all?([a, b, c, d], &(is_binary(&1) and byte_size(&1) == 27)) do
      {:ok, settings,
       %{monthly_budget: a, currency: b, budget_mode: c, retirement_onboarding_dismissed: d}}
    else
      _ -> :error
    end
  end

  def settings(_settings, _stamps), do: :error
end
