defmodule DebtReliefTrackerWeb.Holo.PlanPanelBrowserTest do
  # Real-browser tests of the plan panel's controls: budget input (total and
  # margin modes), strategy switcher, chart-type picker (desktop buttons and
  # the mobile <select>) and the empty-workspace message. The chart itself is
  # covered by plan_chart_browser_test.exs. Run with `mix test --include browser`.
  use DebtReliefTracker.BrowserCase

  import DebtReliefTracker.BrowserExtras

  alias DebtReliefTracker.{Accounts, Debts, Settings}
  alias DebtReliefTrackerWeb.Holo.DashboardPage

  setup do
    {:ok, _} = Accounts.set_tutorial_seen(Accounts.get_default_user!(), true)
    :ok
  end

  defp seed_debt(name \\ "Browser Visa") do
    workspace = Accounts.ensure_default_workspace!()

    {:ok, debt} =
      Debts.create_debt(workspace, nil, %{
        "name" => name,
        "type" => "revolving",
        "balance" => "4500.00",
        "apr" => "12.99",
        "minimum_payment_floor" => "35.00",
        "minimum_payment_rate" => "0.02"
      })

    debt
  end

  defp settings, do: Settings.get_settings!(Accounts.ensure_default_workspace!())

  defp wait_until(fun, tries \\ 60) do
    cond do
      fun.() ->
        :ok

      tries == 0 ->
        flunk("condition never became true")

      true ->
        Process.sleep(100)
        wait_until(fun, tries - 1)
    end
  end

  defp primary?(ctx, selector),
    do:
      js(
        ctx,
        "document.querySelector(#{JSON.encode!(selector)})?.className.includes('btn-primary')"
      )

  describe "budget" do
    test "total mode: typing a budget re-plans and persists", ctx do
      seed_debt()

      ctx
      |> visit_page(DashboardPage)
      |> assert_selector("#this-month-lines")
      |> fill("#budget-input", "400")
      |> assert_text("#stat-payoff-date", "month")

      wait_until(fn ->
        settings().monthly_budget && Decimal.equal?(settings().monthly_budget, 400)
      end)

      refute_selector(ctx, "#budget-save-error")

      # survives a reload
      visit_page(ctx, DashboardPage)
      assert_selector(ctx, "#budget-input")

      wait_js(
        ctx,
        "document.querySelector('#budget-input').value === '400.00' || document.querySelector('#budget-input').value === '400'"
      )
    end

    test "a budget below the minimums shows the budget message, not 'Add a debt'", ctx do
      seed_debt()

      ctx
      |> visit_page(DashboardPage)
      |> assert_selector("#this-month-lines")
      |> fill("#budget-input", "10")
      |> assert_text("#this-month-card", "doesn't cover minimum payments")

      refute text(ctx, "#this-month-card") =~ "Add a debt"
      # the chart area explains the problem as well
      assert_selector(ctx, "#plan-chart-message")
      refute text(ctx, "#plan-chart-message") =~ "Add a debt"
    end

    test "an empty or unparseable budget is not saved and reverts on blur", ctx do
      seed_debt()
      {:ok, _} = Settings.update_settings(settings(), %{"monthly_budget" => "300"})

      ctx
      |> visit_page(DashboardPage)
      |> assert_selector("#this-month-lines")
      |> fill("#budget-input", "")
      |> click("#budget-mode-total")
      |> assert_selector("#this-month-card")

      Process.sleep(1000)
      assert Decimal.equal?(settings().monthly_budget, 300)
      refute count(ctx, "#budget-save-error") > 0
      wait_js(ctx, "parseFloat(document.querySelector('#budget-input').value) === 300")
    end

    test "margin mode: the input is the amount above the minimums and persists as total", ctx do
      seed_debt()
      {:ok, _} = Settings.update_settings(settings(), %{"monthly_budget" => "300"})

      ctx
      |> visit_page(DashboardPage)
      |> assert_selector("#this-month-lines")
      |> click("#budget-mode-margin")
      |> assert_text("label[for=budget-input]", "Additional margin")

      wait_until(fn -> settings().budget_mode == :margin end)

      # 300 total - 90 minimum = 210 margin
      wait_js(ctx, "parseFloat(document.querySelector('#budget-input').value) === 210")

      fill(ctx, "#budget-input", "60")
      wait_until(fn -> Decimal.equal?(settings().monthly_budget, 150) end)

      # back to total mode shows the total
      click(ctx, "#budget-mode-total")
      assert_text(ctx, "label[for=budget-input]", "Monthly budget")
      wait_js(ctx, "parseFloat(document.querySelector('#budget-input').value) === 150")
      wait_until(fn -> settings().budget_mode == :total end)
    end
  end

  describe "strategy and chart type" do
    test "strategy switcher only shows for strategy-dependent charts and selects", ctx do
      seed_debt()
      seed_debt("Store card")

      ctx
      |> visit_page(DashboardPage)
      |> assert_selector("#this-month-lines")
      |> click("#chart-type-simulation")
      |> assert_selector("#strategy-switcher")

      assert primary?(ctx, "#chart-type-simulation")
      assert primary?(ctx, "#strategy-cash_flow")

      ctx
      |> click("#strategy-snowball")
      |> wait_js("document.querySelector('#strategy-snowball').className.includes('btn-primary')")
      |> click("#strategy-avalanche")
      |> wait_js(
        "document.querySelector('#strategy-avalanche').className.includes('btn-primary')"
      )
      |> assert_selector("#plan-chart canvas")

      refute primary?(ctx, "#strategy-snowball")
      assert_text(ctx, "#this-month-card", "pay")
    end

    test "every chart type can be picked and draws something or a message", ctx do
      seed_debt()
      ctx = visit_page(ctx, DashboardPage) |> assert_selector("#this-month-lines")

      for type <-
            ~w(comparison simulation monthly_payments freed_cashflow interest_breakdown retirement_roadmap) do
        click(ctx, "#chart-type-#{type}")

        wait_js(
          ctx,
          "document.querySelector('#chart-type-#{type}').className.includes('btn-primary')"
        )

        wait_js(
          ctx,
          "!!document.querySelector('#plan-chart canvas') || !!document.querySelector('#plan-chart-message')"
        )
      end

      assert errors(ctx) |> Enum.reject(&String.contains?(&1, "404")) == []
    end

    test "mobile: the chart type and strategy pickers are <select>s", ctx do
      seed_debt()
      seed_debt("Store card")

      ctx =
        ctx
        |> set_viewport(375, 800)
        |> visit_page(DashboardPage)
        |> assert_selector("#chart-type-select")

      refute h_overflow?(ctx)
      refute_selector(ctx, "#chart-type-comparison")
      refute_selector(ctx, "#strategy-switcher")

      ctx
      |> select_option("#chart-type-select", "simulation")
      |> assert_selector("#strategy-select")
      |> wait_js("document.querySelector('#chart-type-select').value === 'simulation'")
      |> select_option("#strategy-select", "snowball")
      |> wait_js("document.querySelector('#strategy-select').value === 'snowball'")
      |> assert_selector("#plan-chart canvas")

      # select the controls fit the screen
      for sel <- ["#chart-type-select", "#strategy-select", "#budget-input", "#budget-mode"] do
        r = rect(ctx, sel)
        assert r["x"] >= 0 and r["r"] <= 376, "#{sel} off screen: #{inspect(r)}"
      end

      refute h_overflow?(ctx)
    end
  end

  describe "empty workspace" do
    test "shows the add-a-debt message and no chart", ctx do
      ctx
      |> visit_page(DashboardPage)
      |> assert_text("#this-month-message", "Add a debt")
      |> assert_selector("#plan-chart-message")

      refute count(ctx, "#plan-chart canvas") > 0
      assert errors(ctx) |> Enum.reject(&String.contains?(&1, "404")) == []
    end

    test "typing a budget with no debts does not crash or mislabel", ctx do
      ctx
      |> visit_page(DashboardPage)
      |> assert_text("#this-month-message", "Add a debt")
      |> fill("#budget-input", "250")

      wait_until(fn ->
        settings().monthly_budget && Decimal.equal?(settings().monthly_budget, 250)
      end)

      assert_text(ctx, "#this-month-message", "Add a debt")
    end
  end
end
