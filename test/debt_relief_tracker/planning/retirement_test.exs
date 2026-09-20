defmodule DebtReliefTracker.Planning.RetirementTest do
  use ExUnit.Case, async: true

  alias DebtReliefTracker.Planning.Retirement
  alias DebtReliefTracker.Debts.Debt
  alias DebtReliefTracker.Settings.RetirementProfile

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

  defp profile(attrs) do
    struct(
      %RetirementProfile{
        current_retirement_savings: Decimal.new("0"),
        monthly_retirement_contribution: Decimal.new("0"),
        monthly_gross_income: Decimal.new("0"),
        post_debt_investment_pct: Decimal.new("15.0"),
        expected_annual_return_pct: Decimal.new("7.0")
      },
      attrs
    )
  end

  describe "months_to_retirement/1" do
    test "converts a year gap to months" do
      assert Retirement.months_to_retirement(profile(current_age: 30, retirement_age: 65)) == 420
    end
  end

  describe "combined_months_to_retirement/1" do
    test "is the longest of every profile's own horizon" do
      profiles = [
        profile(current_age: 30, retirement_age: 35),
        profile(current_age: 40, retirement_age: 60)
      ]

      assert Retirement.combined_months_to_retirement(profiles) == 240
    end
  end

  describe "baseline_projection/1" do
    test "zero contribution and zero rate leaves the balance unchanged" do
      profiles = [
        profile(
          current_age: 30,
          retirement_age: 31,
          current_retirement_savings: Decimal.new("1000"),
          monthly_retirement_contribution: Decimal.new("0"),
          expected_annual_return_pct: Decimal.new("0")
        )
      ]

      balances = Retirement.baseline_projection(profiles)
      assert length(balances) == 13
      assert Enum.all?(balances, &Decimal.equal?(&1, Decimal.new("1000")))
    end

    test "compounds growth on the prior balance before adding the month's contribution" do
      profiles = [
        profile(
          current_age: 30,
          retirement_age: 31,
          current_retirement_savings: Decimal.new("1000"),
          monthly_retirement_contribution: Decimal.new("100"),
          # 12% annual -> 1% monthly, so the arithmetic below is easy to hand-check.
          expected_annual_return_pct: Decimal.new("12")
        )
      ]

      [start, month1, month2 | _] = Retirement.baseline_projection(profiles)

      assert Decimal.equal?(start, Decimal.new("1000.00"))
      # 1000 * 1.01 + 100 = 1110.00
      assert Decimal.equal?(month1, Decimal.new("1110.00"))
      # 1110 * 1.01 + 100 = 1221.10
      assert Decimal.equal?(month2, Decimal.new("1221.10"))
    end

    test "sums two people's independently-compounding balances" do
      profiles = [
        profile(
          current_age: 30,
          retirement_age: 31,
          current_retirement_savings: Decimal.new("1000"),
          monthly_retirement_contribution: Decimal.new("0"),
          expected_annual_return_pct: Decimal.new("0")
        ),
        profile(
          current_age: 40,
          retirement_age: 41,
          current_retirement_savings: Decimal.new("500"),
          monthly_retirement_contribution: Decimal.new("0"),
          expected_annual_return_pct: Decimal.new("0")
        )
      ]

      balances = Retirement.baseline_projection(profiles)
      assert length(balances) == 13
      assert Enum.all?(balances, &Decimal.equal?(&1, Decimal.new("1500")))
    end

    test "a shorter-horizon person's balance holds flat (0% return) once padded past their own retirement" do
      profiles = [
        profile(
          current_age: 30,
          retirement_age: 31,
          current_retirement_savings: Decimal.new("0"),
          monthly_retirement_contribution: Decimal.new("100"),
          expected_annual_return_pct: Decimal.new("0")
        ),
        profile(
          current_age: 30,
          retirement_age: 32,
          current_retirement_savings: Decimal.new("0"),
          monthly_retirement_contribution: Decimal.new("0"),
          expected_annual_return_pct: Decimal.new("0")
        )
      ]

      balances = Retirement.baseline_projection(profiles)
      # 24-month combined horizon (the second profile's).
      assert length(balances) == 25
      # First profile contributes for 12 months (reaching 1200), then holds
      # flat at 1200 for the remaining 12 months since the second profile
      # never contributes anything.
      assert Decimal.equal?(Enum.at(balances, 12), Decimal.new("1200.00"))
      assert Decimal.equal?(Enum.at(balances, 24), Decimal.new("1200.00"))
    end
  end

  describe "baseline_contributions/1" do
    test "holds the current contribution flat for the whole horizon" do
      profiles = [
        profile(
          current_age: 30,
          retirement_age: 31,
          monthly_retirement_contribution: Decimal.new("75")
        )
      ]

      contributions = Retirement.baseline_contributions(profiles)
      assert length(contributions) == 12
      assert Enum.all?(contributions, &Decimal.equal?(&1, Decimal.new("75")))
    end

    test "sums contributions across people and zero-pads a shorter horizon" do
      profiles = [
        profile(
          current_age: 30,
          retirement_age: 31,
          monthly_retirement_contribution: Decimal.new("75")
        ),
        profile(
          current_age: 30,
          retirement_age: 32,
          monthly_retirement_contribution: Decimal.new("25")
        )
      ]

      contributions = Retirement.baseline_contributions(profiles)
      assert length(contributions) == 24
      assert Enum.take(contributions, 12) |> Enum.all?(&Decimal.equal?(&1, Decimal.new("100")))
      assert Enum.drop(contributions, 12) |> Enum.all?(&Decimal.equal?(&1, Decimal.new("25")))
    end
  end

  describe "strategy_contributions/4 and strategy_projection_with_contributions/4" do
    test "the contribution schedule switches at the debt-free month, same as strategy_projection/4" do
      debts = [
        debt(
          id: 1,
          type: :installment,
          balance: Decimal.new("200"),
          apr: Decimal.new("0"),
          fixed_payment: Decimal.new("100")
        )
      ]

      profiles = [
        profile(
          current_age: 30,
          retirement_age: 31,
          monthly_retirement_contribution: Decimal.new("50"),
          monthly_gross_income: Decimal.new("4000"),
          post_debt_investment_pct: Decimal.new("15.0")
        )
      ]

      assert {:ok, contributions} =
               Retirement.strategy_contributions(debts, profiles, Decimal.new("100"), :snowball)

      # Debt-free after month 2 -- months 1-2 at $50, months 3-12 at $600
      # (15% of $4000).
      assert Enum.take(contributions, 2) == [Decimal.new("50"), Decimal.new("50")]
      assert Enum.drop(contributions, 2) |> Enum.all?(&Decimal.equal?(&1, Decimal.new("600")))
    end

    test "strategy_projection_with_contributions/4 returns balances consistent with strategy_projection/4" do
      debts = [
        debt(
          id: 1,
          type: :installment,
          balance: Decimal.new("200"),
          apr: Decimal.new("0"),
          fixed_payment: Decimal.new("100")
        )
      ]

      profiles = [
        profile(
          current_age: 30,
          retirement_age: 31,
          monthly_retirement_contribution: Decimal.new("50"),
          monthly_gross_income: Decimal.new("4000"),
          post_debt_investment_pct: Decimal.new("15.0")
        )
      ]

      assert {:ok, %{balances: balances, contributions: contributions}} =
               Retirement.strategy_projection_with_contributions(
                 debts,
                 profiles,
                 Decimal.new("100"),
                 :snowball
               )

      assert {:ok, ^balances} =
               Retirement.strategy_projection(debts, profiles, Decimal.new("100"), :snowball)

      assert length(contributions) == 12
    end

    test "propagates :insufficient_budget like strategy_projection/4" do
      debts = [
        debt(
          id: 1,
          type: :installment,
          balance: Decimal.new("1000"),
          fixed_payment: Decimal.new("500")
        )
      ]

      profiles = [profile(current_age: 30, retirement_age: 31)]

      assert Retirement.strategy_contributions(debts, profiles, Decimal.new("10"), :snowball) ==
               {:error, :insufficient_budget}

      assert Retirement.strategy_projection_with_contributions(
               debts,
               profiles,
               Decimal.new("10"),
               :snowball
             ) == {:error, :insufficient_budget}
    end
  end

  describe "strategy_projection/4" do
    test "switches from the current contribution to the post-debt rate once the strategy is debt-free" do
      debts = [
        debt(
          id: 1,
          type: :installment,
          balance: Decimal.new("200"),
          apr: Decimal.new("0"),
          fixed_payment: Decimal.new("100")
        )
      ]

      profiles = [
        profile(
          current_age: 30,
          retirement_age: 31,
          current_retirement_savings: Decimal.new("0"),
          monthly_retirement_contribution: Decimal.new("50"),
          monthly_gross_income: Decimal.new("4000"),
          post_debt_investment_pct: Decimal.new("15.0"),
          expected_annual_return_pct: Decimal.new("0")
        )
      ]

      assert {:ok, balances} =
               Retirement.strategy_projection(debts, profiles, Decimal.new("100"), :snowball)

      # Debt-free after month 2 (200 balance / 100 payment). Months 1-2
      # contribute the current $50 (0% return, so balances are a running
      # sum); month 3 onward switches to 15% of $4000 = $600/mo.
      assert Decimal.equal?(Enum.at(balances, 0), Decimal.new("0.00"))
      assert Decimal.equal?(Enum.at(balances, 1), Decimal.new("50.00"))
      assert Decimal.equal?(Enum.at(balances, 2), Decimal.new("100.00"))
      assert Decimal.equal?(Enum.at(balances, 3), Decimal.new("700.00"))
      assert Decimal.equal?(Enum.at(balances, 4), Decimal.new("1300.00"))
    end

    test "final balance is strictly greater than the baseline when the post-debt rate is higher" do
      debts = [
        debt(
          id: 1,
          type: :installment,
          balance: Decimal.new("200"),
          apr: Decimal.new("0"),
          fixed_payment: Decimal.new("100")
        )
      ]

      profiles = [
        profile(
          current_age: 30,
          retirement_age: 35,
          current_retirement_savings: Decimal.new("0"),
          monthly_retirement_contribution: Decimal.new("50"),
          monthly_gross_income: Decimal.new("4000"),
          post_debt_investment_pct: Decimal.new("15.0"),
          expected_annual_return_pct: Decimal.new("7.0")
        )
      ]

      {:ok, strategy_balances} =
        Retirement.strategy_projection(debts, profiles, Decimal.new("100"), :snowball)

      baseline_balances = Retirement.baseline_projection(profiles)

      assert Decimal.compare(List.last(strategy_balances), List.last(baseline_balances)) == :gt
    end

    test "with no debts, the post-debt rate applies from month one and the series diverges from baseline" do
      profiles = [
        profile(
          current_age: 30,
          retirement_age: 31,
          current_retirement_savings: Decimal.new("0"),
          monthly_retirement_contribution: Decimal.new("50"),
          monthly_gross_income: Decimal.new("4000"),
          post_debt_investment_pct: Decimal.new("15.0"),
          expected_annual_return_pct: Decimal.new("0")
        )
      ]

      assert {:ok, balances} =
               Retirement.strategy_projection([], profiles, Decimal.new("100"), :snowball)

      baseline = Retirement.baseline_projection(profiles)

      # 12 months at the post-debt rate ($600/mo, 0% return) from month one.
      assert Decimal.equal?(List.last(balances), Decimal.new("7200.00"))
      refute balances == baseline
    end

    test "propagates :insufficient_budget from the underlying simulation" do
      debts = [
        debt(
          id: 1,
          type: :installment,
          balance: Decimal.new("1000"),
          fixed_payment: Decimal.new("500")
        )
      ]

      profiles = [profile(current_age: 30, retirement_age: 31)]

      assert Retirement.strategy_projection(debts, profiles, Decimal.new("10"), :snowball) ==
               {:error, :insufficient_budget}
    end

    test "truncates the schedule to the retirement horizon when it's shorter than the payoff" do
      # Fixed payment 10/mo on a 1200 balance takes 120 months to pay off --
      # far longer than the 12-month horizon below -- so the post-debt rate
      # should never kick in.
      debts = [
        debt(
          id: 1,
          type: :installment,
          balance: Decimal.new("1200"),
          apr: Decimal.new("0"),
          fixed_payment: Decimal.new("10")
        )
      ]

      profiles = [
        profile(
          current_age: 30,
          retirement_age: 31,
          monthly_retirement_contribution: Decimal.new("50"),
          monthly_gross_income: Decimal.new("4000"),
          post_debt_investment_pct: Decimal.new("15.0"),
          expected_annual_return_pct: Decimal.new("0")
        )
      ]

      assert {:ok, balances} =
               Retirement.strategy_projection(debts, profiles, Decimal.new("10"), :snowball)

      assert length(balances) == 13
      assert Decimal.equal?(List.last(balances), Decimal.new("600.00"))
    end

    test "a faster payoff strategy yields a strictly larger final balance than a slower one" do
      debts = [
        debt(
          id: 1,
          type: :revolving,
          balance: Decimal.new("500"),
          apr: Decimal.new("5"),
          minimum_payment_floor: Decimal.new("15"),
          minimum_payment_rate: Decimal.new("0.02")
        ),
        debt(
          id: 2,
          type: :revolving,
          balance: Decimal.new("5000"),
          apr: Decimal.new("28"),
          minimum_payment_floor: Decimal.new("100"),
          minimum_payment_rate: Decimal.new("0.02")
        )
      ]

      profiles = [
        profile(
          current_age: 30,
          retirement_age: 45,
          monthly_retirement_contribution: Decimal.new("100"),
          monthly_gross_income: Decimal.new("5000"),
          post_debt_investment_pct: Decimal.new("15.0"),
          expected_annual_return_pct: Decimal.new("7.0")
        )
      ]

      # At this budget, avalanche (highest APR first) pays off in 43 months
      # versus 45 for cash_flow, per `Planning.simulate/4` -- confirmed
      # directly rather than re-deriving the amortization by hand here.
      {:ok, avalanche} =
        Retirement.strategy_projection(debts, profiles, Decimal.new("200"), :avalanche)

      {:ok, cash_flow} =
        Retirement.strategy_projection(debts, profiles, Decimal.new("200"), :cash_flow)

      # Avalanche clears its debts sooner, so it switches to the (larger)
      # post-debt contribution sooner and compounds longer at that rate.
      assert Decimal.compare(List.last(avalanche), List.last(cash_flow)) == :gt
    end

    test "two people retire independently: the earlier retiree's contributions stop while the other's continue" do
      # A debt that takes 100 months to pay off at this budget -- far longer
      # than either profile's horizon below -- so the post-debt switch never
      # kicks in and both profiles use their current contribution throughout.
      debts = [
        debt(
          id: 1,
          type: :installment,
          balance: Decimal.new("1000"),
          apr: Decimal.new("0"),
          fixed_payment: Decimal.new("10")
        )
      ]

      profiles = [
        profile(
          current_age: 30,
          retirement_age: 31,
          current_retirement_savings: Decimal.new("0"),
          monthly_retirement_contribution: Decimal.new("100"),
          monthly_gross_income: Decimal.new("0"),
          post_debt_investment_pct: Decimal.new("0"),
          expected_annual_return_pct: Decimal.new("0")
        ),
        profile(
          current_age: 30,
          retirement_age: 32,
          current_retirement_savings: Decimal.new("0"),
          monthly_retirement_contribution: Decimal.new("100"),
          monthly_gross_income: Decimal.new("0"),
          post_debt_investment_pct: Decimal.new("0"),
          expected_annual_return_pct: Decimal.new("0")
        )
      ]

      assert {:ok, balances} =
               Retirement.strategy_projection(debts, profiles, Decimal.new("10"), :snowball)

      assert length(balances) == 25
      # Month 12: both have contributed 1200 each -> 2400 combined.
      assert Decimal.equal?(Enum.at(balances, 12), Decimal.new("2400.00"))
      # Month 24: person A stopped at month 12 (stays at 1200), person B
      # reaches 2400 -> 3600 combined.
      assert Decimal.equal?(Enum.at(balances, 24), Decimal.new("3600.00"))
    end
  end
end
