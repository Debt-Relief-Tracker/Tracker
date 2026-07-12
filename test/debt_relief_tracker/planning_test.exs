defmodule DebtReliefTracker.PlanningTest do
  use ExUnit.Case, async: true

  alias DebtReliefTracker.Planning
  alias DebtReliefTracker.Debts.Debt

  defp debt(attrs) do
    struct(
      %Debt{
        balance: Decimal.new("0"),
        apr: Decimal.new("0"),
        minimum_payment_floor: Decimal.new("0"),
        minimum_payment_rate: Decimal.new("0"),
        exclude_from_plan: false,
        status: :active
      },
      attrs
    )
  end

  describe "eligible/1" do
    test "drops paid-off, excluded, and zero-balance debts" do
      debts = [
        debt(id: 1, balance: Decimal.new("100")),
        debt(id: 2, balance: Decimal.new("0")),
        debt(id: 3, balance: Decimal.new("100"), status: :paid_off),
        debt(id: 4, balance: Decimal.new("100"), exclude_from_plan: true),
        debt(id: 5, balance: Decimal.new("100"))
      ]

      assert Planning.eligible(debts) |> Enum.map(& &1.id) == [1, 5]
    end
  end

  describe "order/2" do
    test ":snowball orders by smallest balance first" do
      debts = [debt(id: 1, balance: Decimal.new("500")), debt(id: 2, balance: Decimal.new("100"))]
      assert Planning.order(:snowball, debts) |> Enum.map(& &1.id) == [2, 1]
    end

    test ":avalanche orders by highest APR first" do
      debts = [
        debt(id: 1, balance: Decimal.new("500"), apr: Decimal.new("10")),
        debt(id: 2, balance: Decimal.new("500"), apr: Decimal.new("25"))
      ]

      assert Planning.order(:avalanche, debts) |> Enum.map(& &1.id) == [2, 1]
    end

    test ":cash_flow orders by highest minimum-payment-to-balance ratio first" do
      # id 1: 20/1000 = 2%. id 2: fixed 300/1000 installment = 30%.
      debts = [
        debt(
          id: 1,
          type: :revolving,
          balance: Decimal.new("1000"),
          minimum_payment_rate: Decimal.new("0.02")
        ),
        debt(
          id: 2,
          type: :installment,
          balance: Decimal.new("1000"),
          fixed_payment: Decimal.new("300")
        )
      ]

      assert Planning.order(:cash_flow, debts) |> Enum.map(& &1.id) == [2, 1]
    end
  end

  describe "simulate/3" do
    test "a single 0% APR installment debt pays off in balance/payment months with no interest" do
      debts = [
        debt(
          id: 1,
          type: :installment,
          balance: Decimal.new("1000"),
          apr: Decimal.new("0"),
          fixed_payment: Decimal.new("250")
        )
      ]

      assert {:ok, result} = Planning.simulate(debts, Decimal.new("250"), :snowball)
      assert result.total_months == 4
      assert Decimal.equal?(result.total_interest, Decimal.new(0))

      assert List.last(result.months).lines
             |> hd()
             |> Map.get(:ending_balance)
             |> Decimal.equal?(0)
    end

    test "returns :insufficient_budget when the budget can't cover minimums" do
      debts = [
        debt(
          id: 1,
          type: :installment,
          balance: Decimal.new("1000"),
          fixed_payment: Decimal.new("500")
        ),
        debt(
          id: 2,
          type: :installment,
          balance: Decimal.new("1000"),
          fixed_payment: Decimal.new("500")
        )
      ]

      assert Planning.simulate(debts, Decimal.new("100"), :snowball) ==
               {:error, :insufficient_budget}
    end

    test "cascades extra budget down the fixed order within the same month" do
      debts = [
        debt(
          id: 1,
          type: :installment,
          balance: Decimal.new("50"),
          apr: Decimal.new("0"),
          fixed_payment: Decimal.new("50")
        ),
        debt(
          id: 2,
          type: :installment,
          balance: Decimal.new("1000"),
          apr: Decimal.new("0"),
          fixed_payment: Decimal.new("50")
        )
      ]

      # snowball puts debt 1 (smaller balance) first. Budget = both minimums
      # (50 + 50 = 100) plus 200 extra. Debt 1 only needs 50 total, so the
      # other 200 should cascade into debt 2 in month 1.
      assert {:ok, result} = Planning.simulate(debts, Decimal.new("300"), :snowball)
      [first_month | _] = result.months
      debt_2_line = Enum.find(first_month.lines, &(&1.debt_id == 2))
      assert Decimal.equal?(debt_2_line.payment, Decimal.new("250"))
    end
  end

  describe "compare_strategies/2" do
    test "returns a result for all three strategies" do
      debts = [
        debt(
          id: 1,
          type: :installment,
          balance: Decimal.new("500"),
          fixed_payment: Decimal.new("100")
        ),
        debt(
          id: 2,
          type: :installment,
          balance: Decimal.new("500"),
          fixed_payment: Decimal.new("100")
        )
      ]

      result = Planning.compare_strategies(debts, Decimal.new("300"))
      assert {:ok, _} = result.cash_flow
      assert {:ok, _} = result.snowball
      assert {:ok, _} = result.avalanche
    end
  end

  describe "windfall_cascade/4" do
    test "a lump sum reduces total interest and months versus the baseline" do
      debts = [
        debt(
          id: 1,
          type: :revolving,
          balance: Decimal.new("2000"),
          apr: Decimal.new("24"),
          minimum_payment_floor: Decimal.new("50"),
          minimum_payment_rate: Decimal.new("0.02")
        )
      ]

      assert {:ok, %{interest_saved: interest_saved, months_saved: months_saved}} =
               Planning.windfall_cascade(debts, Decimal.new("100"), :snowball, Decimal.new("500"))

      assert Decimal.positive?(interest_saved)
      assert months_saved > 0
    end
  end

  describe "freed_cashflow_over_time/3" do
    test "freed cash flow reaches the original total minimum once everything is paid off" do
      debts = [
        debt(
          id: 1,
          type: :installment,
          balance: Decimal.new("300"),
          apr: Decimal.new("0"),
          fixed_payment: Decimal.new("100")
        ),
        debt(
          id: 2,
          type: :installment,
          balance: Decimal.new("300"),
          apr: Decimal.new("0"),
          fixed_payment: Decimal.new("100")
        )
      ]

      assert {:ok, freed} =
               Planning.freed_cashflow_over_time(debts, Decimal.new("200"), :snowball)

      assert Decimal.equal?(List.last(freed).freed, Decimal.new("200"))
    end
  end
end
