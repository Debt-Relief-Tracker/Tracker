defmodule DebtReliefTrackerWeb.Holo.PlanTest do
  use ExUnit.Case, async: true

  alias DebtReliefTrackerWeb.Holo.Format
  alias DebtReliefTrackerWeb.Holo.Plan

  @today {2026, 10, 31}

  defp snapshot(debts, settings \\ %{}) do
    %{
      schema_version: 1,
      settings:
        Map.merge(
          %{monthly_budget: nil, currency: "USD", budget_mode: "total", retirement_onboarding_dismissed: false},
          settings
        ),
      debts: debts,
      payments: [],
      activity: []
    }
  end

  defp debt(attrs) do
    Map.merge(
      %{
        id: "d1",
        name: "Loan",
        type: "installment",
        status: "active",
        exclude_from_plan: false,
        balance: 30_000,
        apr_bp: 0,
        fixed_payment: 10_000,
        minimum_payment_floor: nil,
        minimum_payment_rate_bp: nil,
        credit_limit: nil,
        statement_balance: nil,
        statement_date: nil,
        due_day: nil,
        auto_log_mode: "off",
        last_due_handled_on: nil
      },
      Map.new(attrs)
    )
  end

  defp card(attrs) do
    debt(
      Keyword.merge(
        [
          id: "card",
          name: "Visa",
          type: "revolving",
          balance: 450_000,
          apr_bp: 2499,
          fixed_payment: nil,
          minimum_payment_floor: 3_500,
          minimum_payment_rate_bp: 200,
          credit_limit: 900_000
        ],
        attrs
      )
    )
  end

  defp view(snapshot, budget, strategy \\ :cash_flow),
    do: snapshot |> Plan.derive(strategy, budget, @today) |> Plan.view()

  describe "Format.parse_cents/1 and plain_amount/1" do
    test "parses dollars to cents with integer math" do
      assert Format.parse_cents("12") == {:ok, 1200}
      assert Format.parse_cents(" 12.3 ") == {:ok, 1230}
      assert Format.parse_cents("0.05") == {:ok, 5}
      assert Format.parse_cents(".5") == {:ok, 50}
      assert Format.parse_cents("5.") == {:ok, 500}
      assert Format.parse_cents("-3.5") == {:ok, -350}
      assert Format.parse_cents("1.005") == {:ok, 101}
      assert Format.parse_cents("1.004") == {:ok, 100}
      assert Format.parse_cents("1234567.89") == {:ok, 123_456_789}
    end

    test "rejects anything that isn't a plain decimal number" do
      for bad <- ["", " ", "-", ".", "abc", "1,000", "1.2.3", "--1", "1e3", "$5", nil] do
        assert Format.parse_cents(bad) == :error, inspect(bad)
      end
    end

    test "plain_amount/1 is the inverse for input values" do
      assert Format.plain_amount(123_456) == "1234.56"
      assert Format.plain_amount(5) == "0.05"
      assert Format.plain_amount(-5) == "-0.05"
      assert Format.plain_amount(0) == "0.00"
    end
  end

  describe "budget" do
    test "the saved budget, else the 105%-of-minimums default" do
      assert Plan.effective_budget(snapshot([debt([])], %{monthly_budget: 50_000}), nil, :total) == 50_000
      # $100 minimum * 1.05 rounded up to a whole dollar.
      assert Plan.effective_budget(snapshot([debt([])]), nil, :total) == 10_500
      assert Plan.effective_budget(snapshot([]), nil, :total) == 20_000
    end

    test "a typed draft wins; in margin mode it's added to the minimums" do
      s = snapshot([debt([])], %{monthly_budget: 50_000})
      assert Plan.effective_budget(s, "250", :total) == 25_000
      assert Plan.effective_budget(s, "50", :margin) == 10_000 + 5_000
      assert Plan.effective_budget(s, "nonsense", :total) == 50_000
      assert Plan.draft_total(s, nil, :total) == :error
    end

    test "the input shows the total, or the margin over minimums" do
      s = snapshot([debt([])], %{monthly_budget: 15_050})
      assert Plan.budget_input_value(s, :total) == "150.50"
      assert Plan.budget_input_value(s, :margin) == "50.50"
      assert Plan.budget_label(:total) == "Monthly budget"
      assert Plan.budget_label(:margin) == "Additional margin"
    end

    test "budget_mode/1 reads the saved mode" do
      assert Plan.budget_mode(snapshot([], %{budget_mode: "margin"})) == :margin
      assert Plan.budget_mode(snapshot([], %{budget_mode: "total"})) == :total
      assert Plan.budget_mode(snapshot([], %{budget_mode: nil})) == :total
    end
  end

  describe "this-month card" do
    test "lists each debt with a payment, flagging where the extra goes" do
      s = snapshot([debt(id: "a", name: "A"), debt(id: "b", name: "B", balance: 50_000)])
      %{this_month: %{lines: lines, message: nil}} = view(s, 30_000, :snowball)

      assert [%{name: "A", payment: 20_000, extra: true}, %{name: "B", payment: 10_000, extra: false}] =
               lines
    end

    test "no debts at all -> add a debt" do
      assert view(snapshot([]), 20_000).this_month ==
               %{lines: [], message: "Add a debt to see your payoff plan."}
    end

    test "a budget below the minimums is a budget message, not 'add a debt'" do
      %{message: message} = view(snapshot([debt([])]), 5_000).this_month
      assert message =~ "budget doesn't cover minimum payments"
    end

    test "a plan that never converges says so (the LiveView called it a budget problem)" do
      s = snapshot([card(balance: 1_000_000, apr_bp: 5_000, minimum_payment_floor: 100, minimum_payment_rate_bp: 0)])
      %{message: message} = view(s, 200).this_month
      assert message =~ "doesn't pay off within 50 years"
    end

    test "debts that are all paid off or excluded aren't called a budget problem" do
      s = snapshot([debt(status: "paid_off"), debt(id: "x", exclude_from_plan: true)])
      %{message: message} = view(s, 20_000).this_month
      refute message =~ "budget"
      refute message =~ "Add a debt"
    end
  end

  describe "summary stats" do
    test "total paid = debt remaining + projected interest, with payoff date and months" do
      s = snapshot([card([])], %{monthly_budget: 50_000})
      %{stats: stats} = view(s, 50_000)

      assert stats.interest_paid > 0
      assert stats.total_paid == stats.debt_remaining + stats.interest_paid
      assert stats.debt_remaining == 450_000
      assert is_integer(stats.payoff_months)
      assert stats.payoff_date == Plan.month_label(@today, stats.payoff_months)
      assert stats.utilization_bp == 5_000
    end

    test "no utilization without a credit limit; a dash when the plan errors" do
      %{stats: stats} = view(snapshot([debt([])]), 5_000)
      assert stats.utilization_bp == nil
      assert stats.payoff_date == "—"
      assert stats.payoff_months == nil
      assert stats.interest_paid == 0
    end

    test "month_label/2 counts calendar months" do
      assert Plan.month_label({2026, 10, 31}, 0) == "Oct 2026"
      assert Plan.month_label({2026, 10, 31}, 3) == "Jan 2027"
      assert Plan.month_label({2026, 1, 1}, 23) == "Dec 2027"
    end
  end

  describe "chart/2" do
    test "builds the selected chart in the workspace currency" do
      derived = Plan.derive(snapshot([debt([])], %{currency: "EUR"}), :cash_flow, 20_000, @today)
      {nil, config} = Plan.chart(derived, :simulation)
      assert config.options.scales.y.ticks.format.currency == "EUR"
      assert {nil, %{type: "bar"}} = Plan.chart(derived, :comparison)
    end

    test "a too-small budget is reported as a budget problem on every plan chart" do
      derived = Plan.derive(snapshot([debt([])]), :cash_flow, 5_000, @today)

      for type <- [:comparison, :simulation, :monthly_payments, :freed_cashflow] do
        {message, nil} = Plan.chart(derived, type)
        assert message =~ "budget", "#{type}"
      end
    end

    test "retirement roadmap without profiles in the snapshot asks for one" do
      derived = Plan.derive(snapshot([debt([])]), :cash_flow, 20_000, @today)
      {message, nil} = Plan.chart(derived, :retirement_roadmap)
      assert message =~ "retirement profile"
    end
  end
end
