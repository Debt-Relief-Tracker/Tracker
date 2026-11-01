defmodule DebtReliefTrackerWeb.Holo.DebtFlowsBrowserTest do
  # Real-browser end-to-end tests of the Hologram debt flows (sidebar, debt
  # form, payment, log-all-balances, due prompts). Excluded from `mix test`;
  # run with `mix test --include browser <file>`.
  use DebtReliefTracker.BrowserCase

  alias DebtReliefTracker.{Accounts, ActivityLog, Debts, Payments}
  alias DebtReliefTrackerWeb.Holo.DashboardPage

  # Every save re-runs the payoff simulation in the browser (PlanPanel
  # `compare_strategies`, several seconds of blocked JS), during which
  # Playwright can't observe the page; give waits headroom over the 10s default.
  setup_all do
    previous = System.get_env("BROWSER_TEST_TIMEOUT_MS")
    System.put_env("BROWSER_TEST_TIMEOUT_MS", "25000")

    on_exit(fn ->
      if previous,
        do: System.put_env("BROWSER_TEST_TIMEOUT_MS", previous),
        else: System.delete_env("BROWSER_TEST_TIMEOUT_MS")
    end)
  end

  # The first-run tutorial overlay would intercept every click.
  setup do
    {:ok, _} = Accounts.set_tutorial_seen(Accounts.get_default_user!(), true)
    :ok
  end

  defp workspace, do: Accounts.ensure_default_workspace!()

  defp debts, do: Debts.list_debts(workspace())

  defp debt_named(name), do: Enum.find(debts(), &(&1.name == name))

  defp cents(decimal), do: decimal |> Decimal.mult(100) |> Decimal.to_integer()

  defp actions, do: workspace() |> ActivityLog.list_recent() |> Enum.map(& &1.action)

  defp seed_visa(attrs \\ %{}) do
    {:ok, debt} =
      Debts.create_debt(
        workspace(),
        nil,
        Map.merge(
          %{
            "name" => "Visa",
            "type" => "revolving",
            "balance" => "1000.00",
            "apr" => "20",
            "minimum_payment_floor" => "35.00",
            "minimum_payment_rate" => "0.02",
            "credit_limit" => "5000.00"
          },
          attrs
        )
      )

    debt
  end

  defp seed_loan(attrs \\ %{}) do
    {:ok, debt} =
      Debts.create_debt(
        workspace(),
        nil,
        Map.merge(
          %{
            "name" => "Car loan",
            "type" => "installment",
            "balance" => "8000.00",
            "apr" => "6",
            "fixed_payment" => "250.00"
          },
          attrs
        )
      )

    debt
  end

  defp open_dashboard(ctx), do: visit_page(ctx, DashboardPage)

  describe "add / edit / delete" do
    test "adds a revolving debt", ctx do
      ctx
      |> open_dashboard()
      |> click("#add-debt-button")
      |> assert_selector("#debt-form-modal")
      |> fill("#debt-name", "Chase Card")
      |> select("#debt-type", "revolving")
      |> assert_selector("#debt-revolving-fields")
      |> refute_selector("#debt-installment-fields")
      |> fill("#debt-balance", "$1,234.56")
      |> fill("#debt-apr", "19.99")
      |> fill("#debt-minimum-payment-floor", "35")
      |> fill("#debt-minimum-payment-rate", "0.02")
      |> fill("#debt-credit-limit", "5,000")
      |> click("#debt-form-save")
      |> refute_selector("#debt-form-modal")
      |> assert_text("#debt-list", "Chase Card")
      |> assert_text("#debt-list", "$1,234.56")

      debt = debt_named("Chase Card")
      assert debt.type == :revolving
      assert cents(debt.balance) == 123_456
      assert Decimal.equal?(debt.apr, "19.99")
      assert cents(debt.credit_limit) == 500_000
      assert :debt_added in actions()
    end

    test "adds an installment debt with type-specific fields", ctx do
      ctx
      |> open_dashboard()
      |> click("#add-debt-button")
      |> fill("#debt-name", "Laptop BNPL")
      |> select("#debt-type", "installment")
      |> assert_selector("#debt-installment-fields")
      |> refute_selector("#debt-revolving-fields")
      |> refute_selector("#debt-due-day")
      |> fill("#debt-balance", "900")
      |> fill("#debt-apr", "0")
      |> fill("#debt-fixed-payment", "75.50")
      |> select("#debt-auto-log-mode", "confirm")
      |> assert_selector("#debt-due-day")
      |> fill("#debt-due-day", "15")
      |> click("#debt-form-save")
      |> refute_selector("#debt-form-modal")
      |> assert_text("#debt-list", "Laptop BNPL")

      debt = debt_named("Laptop BNPL")
      assert debt.type == :installment
      assert cents(debt.fixed_payment) == 7550
      assert debt.auto_log_mode == :confirm
      assert debt.due_day == 15
    end

    test "shows validation errors and saves nothing", ctx do
      ctx
      |> open_dashboard()
      |> click("#add-debt-button")
      |> click("#debt-form-save")
      |> assert_text("#debt-form", "can't be blank")
      |> assert_selector("#debt-form-modal")
      |> fill("#debt-name", "Oops")
      |> select("#debt-type", "revolving")
      |> fill("#debt-balance", "abc")
      |> fill("#debt-apr", "10")
      |> fill("#debt-minimum-payment-rate", "0.02")
      |> click("#debt-form-save")
      |> assert_text("#debt-form", "is invalid")

      assert debts() == []
    end

    test "edits a debt, prefilled from the snapshot", ctx do
      seed_visa()

      ctx
      |> open_dashboard()
      |> click("#edit-debt-#{debt_named("Visa").id}")
      |> assert_selector("#debt-form-modal")

      assert value(ctx, "#debt-name") == "Visa"
      assert value(ctx, "#debt-balance") == "1000.00"
      assert value(ctx, "#debt-type") == "revolving"

      ctx
      |> fill("#debt-name", "Visa Platinum")
      |> fill("#debt-balance", "$2,000.25")
      |> click("#debt-form-save")
      |> refute_selector("#debt-form-modal")
      |> assert_text("#debt-list", "Visa Platinum")

      debt = debt_named("Visa Platinum")
      assert cents(debt.balance) == 200_025
      assert length(debts()) == 1
      assert :debt_updated in actions()
    end

    test "edit prefills installment fields and switching due-date tracking works", ctx do
      loan = seed_loan(%{"auto_log_mode" => "confirm", "due_day" => "20"})

      ctx
      |> open_dashboard()
      |> click("#edit-debt-#{loan.id}")
      |> assert_selector("#debt-installment-fields")

      assert value(ctx, "#debt-fixed-payment") == "250.00"
      assert value(ctx, "#debt-auto-log-mode") == "confirm"
      assert value(ctx, "#debt-due-day") == "20"

      ctx
      |> select("#debt-auto-log-mode", "off")
      |> refute_selector("#debt-due-day")
      |> click("#debt-form-save")
      |> refute_selector("#debt-form-modal")

      assert debt_named("Car loan").auto_log_mode == :off
    end

    test "deletes a debt after an inline confirm", ctx do
      visa = seed_visa()

      ctx
      |> open_dashboard()
      |> click("#edit-debt-#{visa.id}")
      |> click("#delete-debt-button")
      |> assert_selector("#debt-delete-confirm")
      |> click("#cancel-delete-debt-button")
      |> refute_selector("#debt-delete-confirm")

      assert length(debts()) == 1

      ctx
      |> click("#delete-debt-button")
      |> click("#confirm-delete-debt-button")
      |> refute_selector("#debt-form-modal")
      |> refute_selector("#debt-#{visa.id}")

      assert debts() == []
      assert :debt_deleted in actions()
    end
  end

  describe "payments" do
    test "logs a payment: balance drops by the principal, activity logged", ctx do
      visa = seed_visa()

      ctx
      |> open_dashboard()
      |> click("#log-payment-#{visa.id}")
      |> assert_selector("#payment-modal")
      |> assert_text("#payment-modal-title", "Visa")
      |> fill("#payment-amount", "$150.00")
      |> fill("#payment-principal", "120.00")
      |> fill("#payment-interest", "30.00")
      |> fill("#payment-note", "browser test")
      |> click("#payment-save")
      |> refute_selector("#payment-modal")
      |> assert_text("#debt-sidebar-notice", "Logged payment")
      |> assert_text("#debt-#{visa.id}", "$880.00")

      assert cents(debt_named("Visa").balance) == 88_000
      assert [payment] = Payments.list_payments_for_debt(visa)
      assert cents(payment.amount) == 15_000
      assert :payment_logged in actions()
    end

    test "an overpayment shows an error and changes nothing", ctx do
      visa = seed_visa()

      ctx
      |> open_dashboard()
      |> click("#log-payment-#{visa.id}")
      |> fill("#payment-amount", "1500")
      |> fill("#payment-principal", "1500")
      |> click("#payment-save")
      |> assert_text("#payment-form", "balance")
      |> assert_selector("#payment-modal")

      assert cents(debt_named("Visa").balance) == 100_000
      assert Payments.list_payments_for_debt(visa) == []
    end

    test "payment form validates a blank amount", ctx do
      visa = seed_visa()

      ctx
      |> open_dashboard()
      |> click("#log-payment-#{visa.id}")
      |> click("#payment-save")
      |> assert_text("#payment-form", "can't be blank")

      assert Payments.list_payments_for_debt(visa) == []
    end

    test "marks a debt paid after an inline confirm", ctx do
      visa = seed_visa()

      ctx
      |> open_dashboard()
      |> click("#mark-paid-#{visa.id}")
      |> assert_selector("#confirm-paid-#{visa.id}")
      |> click("#cancel-mark-paid-#{visa.id}")
      |> refute_selector("#confirm-paid-#{visa.id}")

      assert debt_named("Visa").status == :active

      ctx
      |> click("#mark-paid-#{visa.id}")
      |> click("#confirm-mark-paid-#{visa.id}")
      |> assert_text("#debt-sidebar-notice", "marked as paid off")
      |> refute_selector("#mark-paid-#{visa.id}")

      assert debt_named("Visa").status == :paid_off
      assert :debt_paid_off in actions()
    end
  end

  describe "log all balances" do
    test "reconciles every balance, blank entries are left alone", ctx do
      visa = seed_visa()
      loan = seed_loan()

      ctx
      |> open_dashboard()
      |> click("#log-all-balances-button")
      |> assert_selector("#log-all-balances-modal")

      assert value(ctx, "#balance-#{visa.id}") == "1000.00"

      ctx
      |> fill("#balance-#{visa.id}", "$900.10")
      |> fill("#balance-#{loan.id}", "")
      |> click("#log-all-balances-save")
      |> refute_selector("#log-all-balances-modal")
      |> assert_text("#debt-sidebar-notice", "Balances updated")

      assert cents(debt_named("Visa").balance) == 90_010
      assert cents(debt_named("Car loan").balance) == 800_000
    end

    test "rejects an invalid balance", ctx do
      visa = seed_visa()

      ctx
      |> open_dashboard()
      |> click("#log-all-balances-button")
      |> fill("#balance-#{visa.id}", "nope")
      |> click("#log-all-balances-save")
      |> assert_text("#balance-row-#{visa.id}", "is invalid")
      |> assert_selector("#log-all-balances-modal")

      assert cents(debt_named("Visa").balance) == 100_000
    end
  end

  describe "due-payment prompt" do
    test "Log it posts the fixed payment", ctx do
      loan = seed_loan(%{"auto_log_mode" => "confirm", "due_day" => "1"})

      ctx
      |> open_dashboard()
      |> assert_selector("#due-prompt-#{loan.id}")
      |> click("#confirm-due-payment-#{loan.id}")
      |> refute_selector("#due-prompt-#{loan.id}")
      |> assert_text("#debt-sidebar-notice", "Logged")

      assert cents(debt_named("Car loan").balance) == 775_000
      # no-auth mode has no user, so the entry is tagged as an auto-log
      assert Enum.any?(actions(), &(&1 in [:payment_logged, :payment_auto_logged]))
    end

    test "Skip this month dismisses without posting", ctx do
      loan = seed_loan(%{"auto_log_mode" => "confirm", "due_day" => "1"})

      ctx
      |> open_dashboard()
      |> click("#skip-due-payment-#{loan.id}")
      |> refute_selector("#due-prompt-#{loan.id}")
      |> assert_text("#debt-sidebar-notice", "Skipped")

      assert cents(debt_named("Car loan").balance) == 800_000
      assert :due_payment_skipped in actions()
    end
  end

  describe "closing modals" do
    test "Escape closes the modal", ctx do
      ctx
      |> open_dashboard()
      |> click("#add-debt-button")
      |> assert_selector("#debt-form-modal")
      |> press("Escape")
      |> refute_selector("#debt-form-modal")
    end

    test "clicking outside the dialog closes it", ctx do
      ctx
      |> open_dashboard()
      |> click("#add-debt-button")
      |> assert_selector("#debt-form-modal")
      |> click_at(5, 5)
      |> refute_selector("#debt-form-modal")
    end

    test "clicking inside the dialog does not close it", ctx do
      ctx
      |> open_dashboard()
      |> click("#add-debt-button")
      |> click("#debt-form-title")
      |> assert_selector("#debt-form-modal")
    end

    test "Cancel closes the modal", ctx do
      ctx
      |> open_dashboard()
      |> click("#add-debt-button")
      |> click("#debt-form-cancel")
      |> refute_selector("#debt-form-modal")
    end
  end
end
