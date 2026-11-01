defmodule DebtReliefTrackerWeb.Holo.SummaryTest do
  use ExUnit.Case, async: true

  alias DebtReliefTrackerWeb.Holo.Summary

  @settings %{monthly_budget: nil, currency: "USD", budget_mode: "total"}

  defp debt(attrs) do
    Map.merge(
      %{
        id: "d1",
        name: "Visa",
        type: "revolving",
        status: "active",
        exclude_from_plan: false,
        balance: 450_000,
        apr_bp: 2499,
        fixed_payment: nil,
        minimum_payment_floor: 3500,
        minimum_payment_rate_bp: 200,
        credit_limit: nil,
        statement_balance: nil,
        statement_date: nil,
        due_day: nil,
        auto_log_mode: "off",
        last_due_handled_on: nil
      },
      attrs
    )
  end

  test "this_month/2 with no debts is an error, not a crash" do
    snapshot = %{settings: @settings, debts: []}
    assert Summary.this_month(snapshot, :cash_flow) == {:error, :no_debts}
  end

  test "this_month/2 with only paid-off / excluded debts is also :no_debts" do
    snapshot = %{
      settings: @settings,
      debts: [debt(%{status: "paid_off"}), debt(%{id: "d2", exclude_from_plan: true})]
    }

    assert Summary.this_month(snapshot, :snowball) == {:error, :no_debts}
  end

  test "this_month/2 names the target debt and its payment" do
    snapshot = %{settings: @settings, debts: [debt(%{})]}

    assert {:ok, %{target_name: "Visa", payment: payment}} =
             Summary.this_month(snapshot, :avalanche)

    assert payment > 0
  end

  test "monthly_budget/1 defaults to 105% of minimums rounded up, or $200 with no debts" do
    assert Summary.monthly_budget(%{settings: @settings, debts: []}) == 20_000
    # minimum = max(3500, 2% of 450000 = 9000) = 9000; *1.05 = 9450 -> $95
    assert Summary.monthly_budget(%{settings: @settings, debts: [debt(%{})]}) == 9_500
  end
end
