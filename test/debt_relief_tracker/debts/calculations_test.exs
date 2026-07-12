defmodule DebtReliefTracker.Debts.CalculationsTest do
  use ExUnit.Case, async: true

  alias DebtReliefTracker.Debts.Calculations
  alias DebtReliefTracker.Debts.Debt

  defp revolving(attrs) do
    struct(
      %Debt{
        id: 1,
        type: :revolving,
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

  defp installment(attrs) do
    struct(
      %Debt{
        id: 2,
        type: :installment,
        balance: Decimal.new("0"),
        apr: Decimal.new("0"),
        fixed_payment: Decimal.new("0"),
        exclude_from_plan: false,
        status: :active
      },
      attrs
    )
  end

  describe "minimum_payment/1 for revolving debts" do
    test "uses the floor when rate * balance is smaller" do
      debt =
        revolving(
          balance: Decimal.new("1000"),
          minimum_payment_floor: Decimal.new("25"),
          minimum_payment_rate: Decimal.new("0.02")
        )

      assert Decimal.equal?(Calculations.minimum_payment(debt), Decimal.new("25"))
    end

    test "uses rate * balance when it exceeds the floor" do
      debt =
        revolving(
          balance: Decimal.new("2000"),
          minimum_payment_floor: Decimal.new("25"),
          minimum_payment_rate: Decimal.new("0.02")
        )

      assert Decimal.equal?(Calculations.minimum_payment(debt), Decimal.new("40.00"))
    end

    test "never exceeds the balance" do
      debt =
        revolving(
          balance: Decimal.new("10"),
          minimum_payment_floor: Decimal.new("25"),
          minimum_payment_rate: Decimal.new("0.02")
        )

      assert Decimal.equal?(Calculations.minimum_payment(debt), Decimal.new("10"))
    end
  end

  describe "minimum_payment/1 for installment debts" do
    test "uses the fixed payment" do
      debt = installment(balance: Decimal.new("12000"), fixed_payment: Decimal.new("350"))
      assert Decimal.equal?(Calculations.minimum_payment(debt), Decimal.new("350"))
    end

    test "caps the final payment at the remaining balance" do
      debt = installment(balance: Decimal.new("200"), fixed_payment: Decimal.new("350"))
      assert Decimal.equal?(Calculations.minimum_payment(debt), Decimal.new("200"))
    end
  end

  describe "accrued_interest_estimate/2" do
    test "is zero for installment debts" do
      debt = installment(balance: Decimal.new("1000"), apr: Decimal.new("24"))

      assert Decimal.equal?(
               Calculations.accrued_interest_estimate(debt, ~D[2026-08-01]),
               Decimal.new(0)
             )
    end

    test "is zero when there's no statement baseline yet" do
      debt = revolving(balance: Decimal.new("1000"), apr: Decimal.new("24"), statement_date: nil)

      assert Decimal.equal?(
               Calculations.accrued_interest_estimate(debt, ~D[2026-08-01]),
               Decimal.new(0)
             )
    end

    test "accrues simple daily interest on the statement balance since the statement date" do
      debt =
        revolving(
          balance: Decimal.new("1000"),
          apr: Decimal.new("36.5"),
          statement_balance: Decimal.new("1000"),
          statement_date: ~D[2026-07-01]
        )

      # daily rate = 36.5% / 365 = 0.001/day -> 1000 * 0.001 * 30 = 30
      estimate = Calculations.accrued_interest_estimate(debt, ~D[2026-07-31])
      assert Decimal.equal?(estimate, Decimal.new("30.0"))
    end
  end

  describe "estimated_balance/2" do
    test "adds the accrued interest estimate to the confirmed balance" do
      debt =
        revolving(
          balance: Decimal.new("1000"),
          apr: Decimal.new("36.5"),
          statement_balance: Decimal.new("1000"),
          statement_date: ~D[2026-07-01]
        )

      assert Decimal.equal?(
               Calculations.estimated_balance(debt, ~D[2026-07-31]),
               Decimal.new("1030.0")
             )
    end
  end

  describe "lifetime_interest_paid/1" do
    test "sums the interest portion of a list of payments" do
      payments = [
        %{interest_portion: Decimal.new("20.00")},
        %{interest_portion: Decimal.new("15.50")},
        %{interest_portion: nil}
      ]

      assert Decimal.equal?(Calculations.lifetime_interest_paid(payments), Decimal.new("35.50"))
    end
  end

  describe "total_remaining_balance/1" do
    test "sums estimated balances across non-paid-off debts" do
      debts = [
        revolving(id: 1, balance: Decimal.new("500"), status: :active),
        installment(id: 2, balance: Decimal.new("300"), status: :active),
        installment(id: 3, balance: Decimal.new("999"), status: :paid_off)
      ]

      assert Decimal.equal?(Calculations.total_remaining_balance(debts), Decimal.new("800"))
    end
  end
end
