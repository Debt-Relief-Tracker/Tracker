defmodule DebtReliefTracker.Engine.RetirementParityTest do
  # The integer-cents retirement engine must reproduce the Decimal projection
  # (fixtures from test/support/fixtures/generate_retirement_scenarios.exs).
  # Series lengths, contribution schedules and error outcomes match exactly.
  # Balances may drift: every month's growth is rounded to a cent (and the
  # post-debt contribution too), each by at most half a cent, and a cent of
  # drift then compounds with the account. The bound below is the sum over
  # months of the compounded growth factor, one cent per month per person --
  # a worst case that real drift stays far inside.
  use ExUnit.Case, async: true

  alias DebtReliefTracker.Engine.Convert
  alias DebtReliefTracker.Engine.FromSnapshot
  alias DebtReliefTracker.Engine.Retirement

  @scenarios_path Path.expand("../../support/fixtures/engine_scenarios.json", __DIR__)
  @fixture Path.expand("../../support/fixtures/retirement_scenarios.json", __DIR__)
  @debt_scenarios @scenarios_path |> File.read!() |> Jason.decode!() |> Map.fetch!("scenarios")
  @sets @fixture |> File.read!() |> Jason.decode!() |> Map.fetch!("scenarios")

  @atoms %{
    "revolving" => :revolving,
    "installment" => :installment,
    "active" => :active,
    "paid_off" => :paid_off,
    "cash_flow" => :cash_flow,
    "snowball" => :snowball,
    "avalanche" => :avalanche,
    "insufficient_budget" => :insufficient_budget,
    "did_not_converge" => :did_not_converge
  }

  defp engine_profile(row) do
    %{
      current_age: row["current_age"],
      retirement_age: row["retirement_age"],
      current_retirement_savings: Convert.to_cents(row["current_retirement_savings"]),
      monthly_retirement_contribution: Convert.to_cents(row["monthly_retirement_contribution"]),
      monthly_gross_income: Convert.to_cents(row["monthly_gross_income"]),
      post_debt_investment_bp: Convert.percent_to_bp(row["post_debt_investment_pct"]),
      expected_annual_return_bp: Convert.percent_to_bp(row["expected_annual_return_pct"])
    }
  end

  defp engine_debts(scenario_name) do
    scenario = Enum.find(@debt_scenarios, &(&1["name"] == scenario_name))

    Enum.map(scenario["debts"], fn row ->
      Convert.debt(%{
        id: row["id"],
        type: Map.fetch!(@atoms, row["type"]),
        status: Map.fetch!(@atoms, row["status"]),
        exclude_from_plan: row["exclude_from_plan"],
        balance: row["balance"],
        apr: row["apr"],
        fixed_payment: row["fixed_payment"],
        minimum_payment_floor: row["minimum_payment_floor"],
        minimum_payment_rate: row["minimum_payment_rate"],
        credit_limit: row["credit_limit"]
      })
    end)
  end

  defp budget(scenario_name) do
    @debt_scenarios |> Enum.find(&(&1["name"] == scenario_name)) |> Map.fetch!("budget") |> Convert.to_cents()
  end

  # One cent of drift per month per person, compounded at the fastest rate.
  defp tolerance(profiles) do
    months = Retirement.combined_months_to_retirement(profiles)

    Enum.sum(
      for profile <- profiles do
        monthly = 1 + profile.expected_annual_return_bp / 120_000
        ceil(Enum.sum(for k <- 0..(months - 1), do: :math.pow(monthly, k)))
      end
    )
  end

  defp assert_within(actual, expected, tolerance, label) do
    expected = Enum.map(expected, &Convert.to_cents/1)
    assert length(actual) == length(expected), "#{label}: series length"

    for {{a, e}, i} <- actual |> Enum.zip(expected) |> Enum.with_index() do
      assert abs(a - e) <= tolerance,
             "#{label}[#{i}]: #{a} vs #{e} exceeds #{tolerance} cents"
    end
  end

  for set <- @sets do
    describe "profile set #{set["name"]}" do
      @set set

      setup do
        profiles = Enum.map(@set["profiles"], &engine_profile/1)
        %{profiles: profiles, tolerance: tolerance(profiles), set: @set}
      end

      test "horizon matches", %{profiles: profiles, set: set} do
        assert Retirement.combined_months_to_retirement(profiles) == set["months"]
      end

      test "baseline balances are within the drift bound and contributions exact", ctx do
        assert_within(
          Retirement.baseline_projection(ctx.profiles),
          ctx.set["baseline"]["balances"],
          ctx.tolerance,
          "baseline"
        )

        assert Retirement.baseline_contributions(ctx.profiles) ==
                 Enum.map(ctx.set["baseline"]["contributions"], &Convert.to_cents/1)
      end

      test "strategy projections match for every debt scenario", ctx do
        for case_ <- ctx.set["debt_cases"],
            {name, exp} <- case_["strategies"] do
          strategy = Map.fetch!(@atoms, name)
          debts = engine_debts(case_["debt_scenario"])
          budget = budget(case_["debt_scenario"])
          label = "#{case_["debt_scenario"]}/#{name}"

          result =
            Retirement.strategy_projection_with_contributions(debts, ctx.profiles, budget, strategy)

          case exp do
            %{"status" => "error", "reason" => reason} ->
              assert result == {:error, Map.fetch!(@atoms, reason)}, label

            %{"status" => "ok"} ->
              assert {:ok, %{balances: balances, contributions: contributions}} = result
              assert_within(balances, exp["balances"], ctx.tolerance, label)

              # The debt-free month is exact, so the schedule is too (up to
              # the cent the post-debt amount is rounded to, per person).
              assert_within(contributions, exp["contributions"], length(ctx.profiles), label)

              assert {:ok, ^balances} =
                       Retirement.strategy_projection(debts, ctx.profiles, budget, strategy)

              assert {:ok, ^contributions} =
                       Retirement.strategy_contributions(debts, ctx.profiles, budget, strategy)
          end
        end
      end
    end
  end

  test "snapshot-shaped debts and profiles work end to end" do
    debt = %{
      id: "d1",
      name: "Visa",
      type: "revolving",
      status: "active",
      exclude_from_plan: false,
      balance: 300_000,
      apr_bp: 2000,
      fixed_payment: nil,
      minimum_payment_floor: 3500,
      minimum_payment_rate_bp: 200,
      credit_limit: 500_000,
      statement_balance: nil,
      statement_date: nil,
      due_day: nil,
      auto_log_mode: "off",
      last_due_handled_on: nil
    }

    profile = %{
      id: "p1",
      user_id: nil,
      display_name: "Me",
      name: "Me",
      claim_email: nil,
      current_age: 30,
      retirement_age: 31,
      current_retirement_savings: 100_000,
      monthly_retirement_contribution: 10_000,
      monthly_gross_income: 500_000,
      post_debt_investment_bp: 1000,
      expected_annual_return_bp: 0,
      inserted_at: nil
    }

    debts = FromSnapshot.debts(%{debts: [debt]})

    assert {:ok, balances} = Retirement.strategy_projection(debts, [profile], 100_000, :avalanche)
    assert length(balances) == 13
    assert hd(balances) == 100_000
    # 0% return, 12 months: the start plus twelve contributions of $100 or $500.
    assert List.last(balances) >= 100_000 + 12 * 10_000
    assert List.last(balances) <= 100_000 + 12 * 50_000
    assert Retirement.baseline_projection([profile]) |> List.last() == 100_000 + 12 * 10_000
    assert Retirement.baseline_projection([]) == []
    assert Retirement.combined_months_to_retirement([]) == 0
  end
end
