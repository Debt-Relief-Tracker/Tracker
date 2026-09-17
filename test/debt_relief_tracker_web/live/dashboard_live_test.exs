defmodule DebtReliefTrackerWeb.DashboardLiveTest do
  use DebtReliefTrackerWeb.ConnCase

  import Phoenix.LiveViewTest

  alias DebtReliefTracker.{Accounts, Debts, Payments, Repo}

  setup do
    # In production DebtReliefTracker.Boot does this at application start;
    # :run_boot_tasks is disabled in the test env (config/test.exs) since the
    # sandbox isn't checked out yet at boot, so tests seed it explicitly.
    workspace = Accounts.ensure_default_workspace!()
    Debts.seed_placeholders_if_empty!(workspace)
    %{workspace: workspace}
  end

  test "renders the seeded placeholder debts in the rail", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/")

    assert html =~ "Visa Credit Card (example)"
    assert html =~ "Store Card (example)"
    assert html =~ "Auto Loan (example)"
    assert html =~ "This month"
    # Dollar amounts are comma-grouped wherever shown to the user.
    assert html =~ "$4,500.00"
    assert html =~ "$12,000.00"
  end

  test "adding a debt shows up in the rail", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    view |> element("button", "Add debt") |> render_click()
    assert has_element?(view, "h2", "Add debt")

    # Reveal the type-specific fields first (a real browser sends this
    # phx-change the instant the type <select> changes, before Save is ever
    # clicked) -- otherwise Phoenix correctly treats fixed_payment as an
    # "unused" input and the whole two-step flow below wouldn't reflect how
    # the form actually behaves for a user.
    view
    |> form("form[phx-submit=save_debt]", %{"debt" => %{"type" => "installment"}})
    |> render_change()

    html =
      view
      |> form("form[phx-submit=save_debt]", %{
        "debt" => %{
          "name" => "New Test Loan",
          "type" => "installment",
          "balance" => "500.00",
          "apr" => "5.00",
          "fixed_payment" => "100.00"
        }
      })
      |> render_submit()

    assert html =~ "New Test Loan"
    refute has_element?(view, "h2", "Add debt")
  end

  test "adding the first debt to an empty workspace re-simulates instead of misreporting the stale $200 default budget as insufficient",
       %{conn: conn, workspace: workspace} do
    workspace |> Debts.list_debts() |> Enum.each(&Repo.delete!/1)

    {:ok, view, html} = live(conn, ~p"/")
    assert html =~ "Add a debt to compare payoff strategies."

    view |> element("button", "Add debt") |> render_click()

    view
    |> form("form[phx-submit=save_debt]", %{"debt" => %{"type" => "installment"}})
    |> render_change()

    html =
      view
      |> form("form[phx-submit=save_debt]", %{
        "debt" => %{
          "name" => "Big Loan",
          "type" => "installment",
          "balance" => "1000.00",
          "apr" => "5.00",
          "fixed_payment" => "500.00"
        }
      })
      |> render_submit()

    refute html =~ "Add a debt to compare payoff strategies."
    refute html =~ "cover minimum payments"
  end

  test "rejects an add-debt submission missing the type-specific required field", %{
    conn: conn,
    workspace: workspace
  } do
    {:ok, view, _html} = live(conn, ~p"/")

    view |> element("button", "Add debt") |> render_click()

    view
    |> form("form[phx-submit=save_debt]", %{"debt" => %{"type" => "installment"}})
    |> render_change()

    html =
      view
      |> form("form[phx-submit=save_debt]", %{
        "debt" => %{
          "name" => "Bad Loan",
          "type" => "installment",
          "balance" => "500",
          "apr" => "5"
        }
      })
      |> render_submit()

    # The form stays open with the user's input preserved (so they can fix
    # and resubmit) -- what actually matters is that nothing was persisted.
    assert html =~ "can&#39;t be blank"
    assert has_element?(view, "h2", "Add debt")
    refute Enum.any?(Debts.list_debts(workspace), &(&1.name == "Bad Loan"))
  end

  test "logging a payment reduces the debt balance", %{conn: conn, workspace: workspace} do
    debt =
      DebtReliefTracker.Debts.list_debts(workspace)
      |> Enum.find(&(&1.name == "Auto Loan (example)"))

    {:ok, view, _html} = live(conn, ~p"/")

    view
    |> element("button[phx-click=open_log_payment][phx-value-id='#{debt.id}']")
    |> render_click()

    assert has_element?(view, "h2", "Log payment")

    html =
      view
      |> form("form[phx-submit=save_payment]", %{
        "payment" => %{"amount" => "100.00", "paid_on" => "2026-07-11"}
      })
      |> render_submit()

    assert html =~ "Logged payment"
    assert html =~ "$11,900.00"
  end

  test "marking a debt paid off shows it struck through", %{conn: conn, workspace: workspace} do
    debt =
      DebtReliefTracker.Debts.list_debts(workspace)
      |> Enum.find(&(&1.name == "Auto Loan (example)"))

    {:ok, view, _html} = live(conn, ~p"/")

    view
    |> element("button[phx-click=mark_paid][phx-value-id='#{debt.id}']")
    |> render_click()

    assert has_element?(view, "span.line-through", "Auto Loan (example)")
  end

  test "deleting a debt from the edit modal removes it from the rail entirely", %{
    conn: conn,
    workspace: workspace
  } do
    debt =
      DebtReliefTracker.Debts.list_debts(workspace)
      |> Enum.find(&(&1.name == "Auto Loan (example)"))

    {:ok, view, _html} = live(conn, ~p"/")

    view
    |> element("button[phx-click=open_edit_debt][phx-value-id='#{debt.id}']")
    |> render_click()

    assert has_element?(view, "button[phx-click=delete_debt][phx-value-id='#{debt.id}']")

    html =
      view
      |> element("button[phx-click=delete_debt][phx-value-id='#{debt.id}']")
      |> render_click()

    assert html =~ "deleted"
    refute has_element?(view, "h2", "Edit debt")
    refute has_element?(view, "aside li", "Auto Loan (example)")
    refute Enum.any?(Debts.list_debts(workspace), &(&1.id == debt.id))
  end

  test "the delete button only appears on the edit modal, not the add modal", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    view |> element("button", "Add debt") |> render_click()
    assert has_element?(view, "h2", "Add debt")
    refute has_element?(view, "button", "Delete")
  end

  test "a debt excluded from the plan shows greyed out in the rail", %{
    conn: conn,
    workspace: workspace
  } do
    debt =
      Debts.list_debts(workspace)
      |> Enum.find(&(&1.name == "Auto Loan (example)"))

    {:ok, _} = Debts.update_debt(workspace, nil, debt, %{"exclude_from_plan" => "true"})

    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "li.opacity-50", "Auto Loan (example)")
  end

  test "a revolving debt with a credit limit shows its utilization in the rail", %{
    conn: conn,
    workspace: workspace
  } do
    debt =
      Debts.list_debts(workspace)
      |> Enum.find(&(&1.name == "Visa Credit Card (example)"))

    {:ok, _} = Debts.update_debt(workspace, nil, debt, %{"credit_limit" => "9000.00"})

    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "aside li", "50% utilization")
  end

  test "a revolving debt without a credit limit shows no utilization badge", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    refute has_element?(view, "aside li", "utilization")
  end

  test "the overall credit utilization stat only appears once a debt has a credit limit set", %{
    conn: conn,
    workspace: workspace
  } do
    {:ok, view, _html} = live(conn, ~p"/")
    refute has_element?(view, ".stat.bg-pink-600")

    debt =
      Debts.list_debts(workspace)
      |> Enum.find(&(&1.name == "Visa Credit Card (example)"))

    {:ok, _} = Debts.update_debt(workspace, nil, debt, %{"credit_limit" => "9000.00"})

    {:ok, view, _html} = live(conn, ~p"/")
    assert has_element?(view, ".stat.bg-pink-600 .stat-value", "50%")
  end

  test "renders CSV export links for debts and payments in the settings modal", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    html = view |> element("button[phx-click=open_settings]") |> render_click()

    assert html =~ ~s(href="/export/debts.csv")
    assert html =~ ~s(href="/export/payments.csv")
  end

  test "opening the activity log shows human-readable entries for recent mutations", %{
    conn: conn,
    workspace: workspace
  } do
    debt =
      Debts.list_debts(workspace)
      |> Enum.find(&(&1.name == "Auto Loan (example)"))

    {:ok, _} =
      Payments.log_payment(workspace, nil, debt, %{"amount" => "50.00", "paid_on" => "2026-07-11"})

    {:ok, view, _html} = live(conn, ~p"/")

    view |> element("button", "Activity log") |> render_click()
    html = render(view)

    assert has_element?(view, "h2", "Activity log")
    assert html =~ "added Auto Loan (example)"
    assert html =~ "logged a $50.00 payment on Auto Loan (example)"
  end

  test "closing the activity log hides it again", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    view |> element("button", "Activity log") |> render_click()
    assert has_element?(view, "h2", "Activity log")

    view |> element("button", "Close") |> render_click()

    refute has_element?(view, "h2", "Activity log")
  end

  test "switching chart type pushes a matching Chart.js config to the PlanChart hook", %{
    conn: conn,
    workspace: workspace
  } do
    # interest_breakdown has nothing to plot until at least one payment is
    # logged (docs/plan.md) -- log one so all four chart types have real
    # data, matching this test's intent (every switch produces a real chart).
    debt = Debts.list_debts(workspace) |> hd()

    {:ok, _} =
      Payments.log_payment(workspace, nil, debt, %{
        "amount" => "50.00",
        "paid_on" => ~D[2026-07-11]
      })

    {:ok, view, _html} = live(conn, ~p"/")
    assert_push_event(view, "plan-chart-data", %{type: "bar"})

    for {type, js_type} <- [
          {"simulation", "line"},
          {"monthly_payments", "line"},
          {"freed_cashflow", "line"},
          {"interest_breakdown", "doughnut"},
          {"comparison", "bar"}
        ] do
      view |> element("button[phx-click=select_chart][phx-value-type=#{type}]") |> render_click()
      assert_push_event(view, "plan-chart-data", %{type: ^js_type})
      assert has_element?(view, "canvas#plan-chart")
    end
  end

  test "switching strategy re-simulates the plan", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    view |> element("button[phx-click=select_chart][phx-value-type=simulation]") |> render_click()

    html =
      view
      |> element("button[phx-click=select_strategy][phx-value-strategy=avalanche]")
      |> render_click()

    assert html =~ "Avalanche"
  end

  test "updating the monthly budget re-simulates the this-month card", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    html =
      view
      |> form("form[phx-change=update_budget]", %{"monthly_budget" => "1000"})
      |> render_change()

    assert html =~ "This month"
  end

  test "the budget input's step allows cents, so margin-mode's fractional display never step-mismatches",
       %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/")

    assert html =~ ~s(step="0.01")

    html =
      view
      |> element("button[phx-click=select_budget_mode][phx-value-mode=margin]")
      |> render_click()

    assert html =~ ~s(step="0.01")
  end

  test "renders the summary stat cards in order: total paid, interest paid, debt remaining, payoff date",
       %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/")

    assert [total_i, interest_i, remaining_i, payoff_i] =
             Enum.map(
               ["Total Paid", "Interest Paid", "Debt Remaining", "Payoff Date"],
               fn label ->
                 :binary.match(html, label) |> elem(0)
               end
             )

    assert total_i < interest_i
    assert interest_i < remaining_i
    assert remaining_i < payoff_i
  end

  test "total paid and interest paid stats project the remaining plan, not payment history", %{
    conn: conn
  } do
    {:ok, view, _html} = live(conn, ~p"/")

    # No payments have been logged yet in this fresh workspace, so a
    # history-based figure would read $0.00 -- these instead project the
    # interest/total still to be paid under the current plan, so they must
    # be non-zero and satisfy total = debt_remaining + interest.
    total = view |> element(".stat.bg-purple-600 .stat-value") |> render() |> extract_money()
    interest = view |> element(".stat.bg-orange-600 .stat-value") |> render() |> extract_money()
    remaining = view |> element(".stat.bg-yellow-500 .stat-value") |> render() |> extract_money()

    refute Decimal.equal?(interest, 0)
    assert Decimal.equal?(total, Decimal.add(remaining, interest))
  end

  test "the payoff date box also shows months remaining", %{conn: conn, workspace: workspace} do
    {:ok, view, html} = live(conn, ~p"/")

    [budget_str] =
      Regex.run(~r/name="monthly_budget"[^>]*value="([^"]+)"/, html, capture: :all_but_first)

    budget = Decimal.new(budget_str)

    debts = Debts.list_debts(workspace)

    {:ok, %{total_months: months}} =
      DebtReliefTracker.Planning.simulate(debts, budget, :cash_flow)

    desc = view |> element(".stat.bg-teal-600 .stat-desc") |> render()
    assert desc =~ "#{months} months left"
  end

  defp extract_money(html) do
    html
    |> String.replace(~r/<[^>]+>/, "")
    |> String.replace(~r/[$,]/, "")
    |> String.trim()
    |> Decimal.new()
  end

  test "toggling budget mode to margin changes the input's label and displayed value", %{
    conn: conn
  } do
    {:ok, view, html} = live(conn, ~p"/")

    assert html =~ "Monthly budget"

    html =
      view
      |> element("button[phx-click=select_budget_mode][phx-value-mode=margin]")
      |> render_click()

    assert html =~ "Additional margin"
  end

  test "selecting a currency persists it and re-renders balances with the new symbol", %{
    conn: conn,
    workspace: workspace
  } do
    {:ok, view, html} = live(conn, ~p"/")
    assert html =~ "$4,500.00"

    view |> element("button[phx-click=open_settings]") |> render_click()

    html =
      view
      |> form("form[phx-change=select_currency]", %{"currency" => "EUR"})
      |> render_change()

    assert html =~ "€4,500.00"
    refute html =~ "$4,500.00"

    settings = DebtReliefTracker.Settings.get_settings!(workspace)
    assert settings.currency == "EUR"
  end

  test "renaming the tracker from the settings modal updates the header and persists", %{
    conn: conn,
    workspace: workspace
  } do
    {:ok, view, _html} = live(conn, ~p"/")

    view |> element("button[phx-click=open_settings]") |> render_click()

    html =
      view
      |> form("#workspace-name-form", %{"workspace" => %{"name" => "Our Debts"}})
      |> render_submit()

    assert html =~ "Our Debts"
    assert DebtReliefTracker.Accounts.get_workspace!(workspace.id).name == "Our Debts"
  end

  test "entering a value in margin mode stores monthly_budget as minimums + margin", %{
    conn: conn,
    workspace: workspace
  } do
    {:ok, view, _html} = live(conn, ~p"/")

    view
    |> element("button[phx-click=select_budget_mode][phx-value-mode=margin]")
    |> render_click()

    view
    |> form("form[phx-change=update_budget]", %{"monthly_budget" => "50"})
    |> render_change()

    total_minimums =
      DebtReliefTracker.Planning.total_minimum_payments(Debts.list_debts(workspace))

    settings = DebtReliefTracker.Settings.get_settings!(workspace)
    assert Decimal.equal?(settings.monthly_budget, Decimal.add(total_minimums, Decimal.new("50")))
  end

  test "log all balances reconciles each active debt", %{conn: conn, workspace: workspace} do
    debt =
      DebtReliefTracker.Debts.list_debts(workspace)
      |> Enum.find(&(&1.name == "Visa Credit Card (example)"))

    {:ok, view, _html} = live(conn, ~p"/")

    view |> element("button", "Log all balances") |> render_click()
    assert has_element?(view, "h2", "Log all balances")

    html =
      view
      |> form("form[phx-submit=save_log_all_balances]", %{
        "balances" => %{to_string(debt.id) => "4000.00"}
      })
      |> render_submit()

    assert html =~ "Balances updated"

    reloaded = DebtReliefTracker.Debts.get_debt!(workspace, debt.id)
    assert Decimal.equal?(reloaded.balance, Decimal.new("4000.00"))
  end

  describe "auto-logged payments" do
    test "requires a due day once due-date tracking is turned on", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      view |> element("button", "Add debt") |> render_click()

      view
      |> form("form[phx-submit=save_debt]", %{"debt" => %{"type" => "installment"}})
      |> render_change()

      # A real user picking "Prompt me to confirm" fires this phx-change too,
      # revealing the due_day field (and marking it "used" for error display)
      # before the debt is ever submitted -- mirror that here rather than
      # jumping straight to render_submit with auto_log_mode already set,
      # which would leave due_day absent from the payload entirely (never
      # rendered, so never submitted) instead of present-but-blank.
      view
      |> form("form[phx-submit=save_debt]", %{
        "debt" => %{"type" => "installment", "auto_log_mode" => "confirm"}
      })
      |> render_change()

      html =
        view
        |> form("form[phx-submit=save_debt]", %{
          "debt" => %{
            "name" => "New Loan",
            "type" => "installment",
            "balance" => "500.00",
            "apr" => "5.00",
            "fixed_payment" => "100.00",
            "auto_log_mode" => "confirm"
          }
        })
        |> render_submit()

      assert html =~ "can&#39;t be blank"
      assert has_element?(view, "h2", "Add debt")

      refute Enum.any?(
               Debts.list_debts(Accounts.ensure_default_workspace!()),
               &(&1.name == "New Loan")
             )
    end

    test "a confirm-mode debt whose due date has passed shows a prompt in the This month card", %{
      conn: conn,
      workspace: workspace
    } do
      {:ok, debt} =
        Debts.create_debt(workspace, nil, %{
          "name" => "Auto Loan Due",
          "type" => "installment",
          "balance" => "1000.00",
          "apr" => "5.00",
          "fixed_payment" => "150.00",
          "auto_log_mode" => "confirm",
          "due_day" => to_string(Date.utc_today().day)
        })

      {:ok, view, html} = live(conn, ~p"/")

      assert html =~ "Auto Loan Due payment ($150.00) is due."

      assert has_element?(
               view,
               "button[phx-click=confirm_due_payment][phx-value-id='#{debt.id}']"
             )

      assert has_element?(view, "button[phx-click=skip_due_payment][phx-value-id='#{debt.id}']")
    end

    test "clicking \"Log it\" posts the payment and clears the prompt", %{
      conn: conn,
      workspace: workspace
    } do
      {:ok, debt} =
        Debts.create_debt(workspace, nil, %{
          "name" => "Auto Loan Due",
          "type" => "installment",
          "balance" => "1000.00",
          "apr" => "5.00",
          "fixed_payment" => "150.00",
          "auto_log_mode" => "confirm",
          "due_day" => to_string(Date.utc_today().day)
        })

      {:ok, view, _html} = live(conn, ~p"/")

      html =
        view
        |> element("button[phx-click=confirm_due_payment][phx-value-id='#{debt.id}']")
        |> render_click()

      assert html =~ "Logged Auto Loan Due&#39;s payment."
      refute html =~ "is due."

      reloaded = Debts.get_debt!(workspace, debt.id)
      assert Decimal.equal?(reloaded.balance, Decimal.new("850.00"))
      assert reloaded.last_due_handled_on == Date.utc_today()
    end

    test "clicking \"Skip this month\" clears the prompt without posting a payment", %{
      conn: conn,
      workspace: workspace
    } do
      {:ok, debt} =
        Debts.create_debt(workspace, nil, %{
          "name" => "Auto Loan Due",
          "type" => "installment",
          "balance" => "1000.00",
          "apr" => "5.00",
          "fixed_payment" => "150.00",
          "auto_log_mode" => "confirm",
          "due_day" => to_string(Date.utc_today().day)
        })

      {:ok, view, _html} = live(conn, ~p"/")

      html =
        view
        |> element("button[phx-click=skip_due_payment][phx-value-id='#{debt.id}']")
        |> render_click()

      assert html =~ "Skipped Auto Loan Due this month."
      refute html =~ "is due."

      reloaded = Debts.get_debt!(workspace, debt.id)
      assert Decimal.equal?(reloaded.balance, Decimal.new("1000.00"))
      assert reloaded.last_due_handled_on == Date.utc_today()
    end

    test "an automatic payment posted in the background refreshes the dashboard", %{
      conn: conn,
      workspace: workspace
    } do
      {:ok, debt} =
        Debts.create_debt(workspace, nil, %{
          "name" => "Auto Loan Auto",
          "type" => "installment",
          "balance" => "1000.00",
          "apr" => "5.00",
          "fixed_payment" => "150.00",
          "auto_log_mode" => "automatic",
          "due_day" => to_string(Date.utc_today().day)
        })

      {:ok, view, _html} = live(conn, ~p"/")

      {:ok, _} = DebtReliefTracker.DuePayments.post_due_payment(workspace, nil, debt)
      send(view.pid, {:due_payment_posted, debt.id})

      html = render(view)
      assert html =~ "An automatic payment was posted."
      assert html =~ "$850.00"
    end
  end
end
