defmodule DebtReliefTrackerWeb.Holo.DualModeFlowsBrowserTest do
  @moduledoc """
  The dashboard's behaviour flows, run in BOTH modes from one body: plaintext
  (`:plain`, server-side `Storage`) and E2EE (`:e2ee`, the decrypted
  `VaultDoc` in the browser, saved encrypted). They mirror
  `DebtFlowsBrowserTest`, `PlanPanelBrowserTest`, `RetirementBrowserTest` and
  the settings / activity parts of `ChromeBrowserTest`, but assert only
  through the UI (the E2EE server holds no plaintext to read). After each
  kind of change the page is reloaded (and, in E2EE mode, locked/unlocked
  from scratch): the change must have survived, i.e. it was saved (encrypted).
  Each E2EE test ends by scanning every table of the server database for the
  unique marker strings it used in names and notes.
  """
  use DebtReliefTracker.BrowserCase

  import DebtReliefTracker.E2EEBrowser
  import DebtReliefTracker.BrowserExtras

  alias DebtReliefTracker.Accounts
  alias DebtReliefTrackerWeb.Holo.DashboardPage

  @pass "correct horse battery staple 77"

  for mode <- [:plain, :e2ee] do
    describe "#{mode}" do
      @describetag mode: mode

      setup %{mode: mode} do
        {:ok, _} = Accounts.set_tutorial_seen(Accounts.get_default_user!(), true)
        if mode == :e2ee, do: e2ee_on(hook: false)
        :ok
      end

      # --- add / edit / delete -------------------------------------------------

      test "adds a revolving debt", %{mode: mode} = ctx do
        ctx = start(ctx, mode)

        ctx
        |> click("#add-debt-button")
        |> assert_selector("#debt-form-modal")
        |> fill("#debt-name", "ZQXVisa Chase")
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
        |> assert_text("#debt-list", "ZQXVisa Chase")
        |> assert_text("#debt-list", "$1,234.56")

        ctx = persist(ctx, mode)
        assert_text(ctx, "#debt-list", "ZQXVisa Chase")
        assert_text(ctx, "#debt-list", "$1,234.56")
        finish(ctx, mode, ["ZQXVisa"])
      end

      test "adds an installment debt with type-specific fields", %{mode: mode} = ctx do
        ctx = start(ctx, mode)

        ctx
        |> click("#add-debt-button")
        |> fill("#debt-name", "ZQXLaptop BNPL")
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
        |> assert_text("#debt-list", "ZQXLaptop BNPL")

        ctx = persist(ctx, mode)
        id = debt_id(ctx, "ZQXLaptop BNPL")
        click(ctx, "#edit-debt-#{id}")
        assert_selector(ctx, "#debt-installment-fields")
        assert input_value(ctx, "#debt-fixed-payment") == "75.50"
        assert input_value(ctx, "#debt-auto-log-mode") == "confirm"
        assert input_value(ctx, "#debt-due-day") == "15"
        finish(ctx, mode, ["ZQXLaptop"])
      end

      test "shows validation errors and saves nothing", %{mode: mode} = ctx do
        ctx = start(ctx, mode)

        ctx
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

        assert count(ctx, "#debt-list li") == 0
      end

      test "edits a debt, prefilled from the snapshot", %{mode: mode} = ctx do
        ctx = start(ctx, mode)
        id = add_visa(ctx, "ZQXEdit Visa")

        ctx
        |> click("#edit-debt-#{id}")
        |> assert_selector("#debt-form-modal")

        assert input_value(ctx, "#debt-name") == "ZQXEdit Visa"
        assert input_value(ctx, "#debt-balance") in ["1000", "1000.00"]
        assert input_value(ctx, "#debt-type") == "revolving"

        ctx
        |> fill("#debt-name", "ZQXEdit Platinum")
        |> fill("#debt-balance", "$2,000.25")
        |> click("#debt-form-save")
        |> refute_selector("#debt-form-modal")
        |> assert_text("#debt-list", "ZQXEdit Platinum")
        |> assert_text("#debt-#{id}", "$2,000.25")

        ctx = persist(ctx, mode)
        assert_text(ctx, "#debt-#{id}", "ZQXEdit Platinum")
        assert_text(ctx, "#debt-#{id}", "$2,000.25")
        assert count(ctx, "#debt-list li") == 1
        finish(ctx, mode, ["ZQXEdit"])
      end

      test "very long names and the non-USD currency render and persist", %{mode: mode} = ctx do
        ctx = start(ctx, mode)
        long = "ZQXLong " <> String.duplicate("w", 100)
        id = add_visa(ctx, long)

        ctx
        |> click("#settings-button")
        |> assert_selector("#settings-modal")
        |> select("#settings-currency", "EUR")
        |> click("#settings-save")
        |> refute_selector("#settings-modal")
        |> assert_text("#debt-#{id}", "€1,000.00")

        ctx = persist(ctx, mode)
        assert_text(ctx, "#debt-#{id}", "€1,000.00")
        assert text(ctx, "#debt-#{id}") =~ long
        finish(ctx, mode, ["ZQXLong"])
      end

      test "deletes a debt after an inline confirm", %{mode: mode} = ctx do
        ctx = start(ctx, mode)
        id = add_visa(ctx, "ZQXDelete Visa")

        ctx
        |> click("#edit-debt-#{id}")
        |> click("#delete-debt-button")
        |> assert_selector("#debt-delete-confirm")
        |> click("#cancel-delete-debt-button")
        |> refute_selector("#debt-delete-confirm")

        assert count(ctx, "#debt-list li") == 1

        ctx
        |> click("#delete-debt-button")
        |> click("#confirm-delete-debt-button")
        |> refute_selector("#debt-form-modal")
        |> refute_selector("#debt-#{id}")

        ctx = persist(ctx, mode)
        refute_selector(ctx, "#debt-#{id}")
        assert count(ctx, "#debt-list li") == 0
        finish(ctx, mode, ["ZQXDelete"])
      end

      # --- payments -------------------------------------------------------------

      test "logs a payment: balance drops by the principal, activity logged",
           %{mode: mode} = ctx do
        ctx = start(ctx, mode)
        id = add_visa(ctx, "ZQXPay Visa")

        ctx
        |> click("#log-payment-#{id}")
        |> assert_selector("#payment-modal")
        |> assert_text("#payment-modal-title", "ZQXPay Visa")
        |> fill("#payment-amount", "$150.00")
        |> fill("#payment-principal", "120.00")
        |> fill("#payment-interest", "30.00")
        |> fill("#payment-note", "ZQXnote browser test")
        |> click("#payment-save")
        |> refute_selector("#payment-modal")
        |> assert_text("#debt-sidebar-notice", "Logged payment")
        |> assert_text("#debt-#{id}", "$880.00")

        ctx = persist(ctx, mode)
        assert_text(ctx, "#debt-#{id}", "$880.00")

        ctx
        |> click("#activity-log-button")
        |> assert_selector("#activity-log-modal")
        |> assert_text("#activity-log-entries", "logged a $150.00 payment on ZQXPay Visa")

        finish(ctx, mode, ["ZQXPay", "ZQXnote"])
      end

      test "an overpayment shows an error and changes nothing", %{mode: mode} = ctx do
        ctx = start(ctx, mode)
        id = add_visa(ctx, "ZQXOver Visa")

        ctx
        |> click("#log-payment-#{id}")
        |> fill("#payment-amount", "1500")
        |> fill("#payment-principal", "1500")
        |> click("#payment-save")
        |> assert_text("#payment-form", "balance")
        |> assert_selector("#payment-modal")
        |> click("#payment-cancel")
        |> assert_text("#debt-#{id}", "$1,000.00")

        finish(persist(ctx, mode), mode, ["ZQXOver"])
      end

      test "payment form validates a blank amount", %{mode: mode} = ctx do
        ctx = start(ctx, mode)
        id = add_visa(ctx, "ZQXBlank Visa")

        ctx
        |> click("#log-payment-#{id}")
        |> click("#payment-save")
        |> assert_text("#payment-form", "can't be blank")
      end

      test "marks a debt paid after an inline confirm", %{mode: mode} = ctx do
        ctx = start(ctx, mode)
        id = add_visa(ctx, "ZQXPaidOff Visa")

        ctx
        |> click("#mark-paid-#{id}")
        |> assert_selector("#confirm-paid-#{id}")
        |> click("#cancel-mark-paid-#{id}")
        |> refute_selector("#confirm-paid-#{id}")
        |> assert_selector("#mark-paid-#{id}")
        |> click("#mark-paid-#{id}")
        |> click("#confirm-mark-paid-#{id}")
        |> assert_text("#debt-sidebar-notice", "marked as paid off")
        |> refute_selector("#mark-paid-#{id}")

        ctx = persist(ctx, mode)
        assert_selector(ctx, "#debt-#{id}")
        refute_selector(ctx, "#mark-paid-#{id}")
        finish(ctx, mode, ["ZQXPaidOff"])
      end

      # --- log all balances -----------------------------------------------------

      test "log all balances: reconciles, blank entries are left alone, invalid is rejected",
           %{mode: mode} = ctx do
        ctx = start(ctx, mode)
        visa = add_visa(ctx, "ZQXAll Visa")
        loan = add_loan(ctx, "ZQXAll Loan")

        ctx
        |> click("#log-all-balances-button")
        |> assert_selector("#log-all-balances-modal")

        assert input_value(ctx, "#balance-#{visa}") == "1000.00"

        ctx
        |> fill("#balance-#{visa}", "nope")
        |> click("#log-all-balances-save")
        |> assert_text("#balance-row-#{visa}", "is invalid")
        |> assert_selector("#log-all-balances-modal")
        |> fill("#balance-#{visa}", "$900.10")
        |> fill("#balance-#{loan}", "")
        |> click("#log-all-balances-save")
        |> refute_selector("#log-all-balances-modal")
        |> assert_text("#debt-sidebar-notice", "Balances updated")
        |> assert_text("#debt-#{visa}", "$900.10")
        |> assert_text("#debt-#{loan}", "$8,000.00")

        ctx = persist(ctx, mode)
        assert_text(ctx, "#debt-#{visa}", "$900.10")
        assert_text(ctx, "#debt-#{loan}", "$8,000.00")
        finish(ctx, mode, ["ZQXAll"])
      end

      # --- due prompts ----------------------------------------------------------

      test "due prompt: Log it posts the fixed payment", %{mode: mode} = ctx do
        ctx = start(ctx, mode)
        loan = add_loan(ctx, "ZQXDue Loan", "confirm")
        ctx = persist(ctx, mode)

        ctx
        |> assert_selector("#due-prompt-#{loan}")
        |> click("#confirm-due-payment-#{loan}")
        |> refute_selector("#due-prompt-#{loan}")
        |> assert_text("#debt-sidebar-notice", "Logged")
        |> assert_text("#debt-#{loan}", "$7,750.00")

        ctx = persist(ctx, mode)
        assert_text(ctx, "#debt-#{loan}", "$7,750.00")
        refute_selector(ctx, "#due-prompt-#{loan}")
        finish(ctx, mode, ["ZQXDue"])
      end

      test "due prompt: Skip this month dismisses without posting", %{mode: mode} = ctx do
        ctx = start(ctx, mode)
        loan = add_loan(ctx, "ZQXSkip Loan", "confirm")
        ctx = persist(ctx, mode)

        ctx
        |> click("#skip-due-payment-#{loan}")
        |> refute_selector("#due-prompt-#{loan}")
        |> assert_text("#debt-sidebar-notice", "Skipped")
        |> assert_text("#debt-#{loan}", "$8,000.00")

        ctx = persist(ctx, mode)
        refute_selector(ctx, "#due-prompt-#{loan}")
        assert_text(ctx, "#debt-#{loan}", "$8,000.00")
        finish(ctx, mode, ["ZQXSkip"])
      end

      # --- modals ---------------------------------------------------------------

      test "modals close with Escape, outside click and Cancel", %{mode: mode} = ctx do
        ctx = start(ctx, mode)

        ctx
        |> click("#add-debt-button")
        |> assert_selector("#debt-form-modal")
        |> press("Escape")
        |> refute_selector("#debt-form-modal")
        |> click("#add-debt-button")
        |> click_xy(5, 5)
        |> refute_selector("#debt-form-modal")
        |> click("#add-debt-button")
        |> click("#debt-form-title")
        |> assert_selector("#debt-form-modal")
        |> click("#debt-form-cancel")
        |> refute_selector("#debt-form-modal")
      end

      # --- plan panel -----------------------------------------------------------

      test "budget: typing re-plans and persists; a low budget shows the budget message",
           %{mode: mode} = ctx do
        ctx = start(ctx, mode)
        add_visa(ctx, "ZQXPlan Visa", "4500")

        ctx
        |> assert_selector("#this-month-lines")
        |> fill("#budget-input", "10")
        |> assert_text("#this-month-card", "doesn't cover minimum payments")
        |> fill("#budget-input", "400")
        |> assert_text("#stat-payoff-date", "month")

        refute text(ctx, "#this-month-card") =~ "Add a debt"
        Process.sleep(1500)
        refute_selector(ctx, "#budget-save-error")

        ctx = persist(ctx, mode)
        assert_selector(ctx, "#budget-input")

        wait_js(
          ctx,
          "['400.00','400'].includes(document.querySelector('#budget-input').value)"
        )

        finish(ctx, mode, ["ZQXPlan"])
      end

      test "budget margin mode persists as the total", %{mode: mode} = ctx do
        ctx = start(ctx, mode)
        add_visa(ctx, "ZQXMargin Visa", "4500")

        ctx
        |> assert_selector("#this-month-lines")
        |> fill("#budget-input", "300")
        |> click("#budget-mode-margin")
        |> assert_text("label[for=budget-input]", "Additional margin")

        # 300 total - 90 minimum = 210 margin
        wait_js(ctx, "parseFloat(document.querySelector('#budget-input').value) === 210")
        fill(ctx, "#budget-input", "60")
        Process.sleep(1500)

        ctx = persist(ctx, mode)
        assert_text(ctx, "label[for=budget-input]", "Additional margin")
        wait_js(ctx, "parseFloat(document.querySelector('#budget-input').value) === 60")
        click(ctx, "#budget-mode-total")
        assert_text(ctx, "label[for=budget-input]", "Monthly budget")
        wait_js(ctx, "parseFloat(document.querySelector('#budget-input').value) === 150")
        finish(ctx, mode, ["ZQXMargin"])
      end

      test "strategy switcher and every chart type", %{mode: mode} = ctx do
        ctx = start(ctx, mode)
        add_visa(ctx, "ZQXChart Visa", "4500")
        add_visa(ctx, "ZQXChart Store", "800")

        ctx
        |> assert_selector("#this-month-lines")
        |> click("#chart-type-simulation")
        |> assert_selector("#strategy-switcher")
        |> click("#strategy-snowball")
        |> wait_js(
          "document.querySelector('#strategy-snowball').className.includes('btn-primary')"
        )
        |> assert_selector("#plan-chart canvas")

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

      test "empty workspace: the add-a-debt message and no chart", %{mode: mode} = ctx do
        ctx = start(ctx, mode)

        ctx
        |> assert_text("#this-month-message", "Add a debt")
        |> assert_selector("#plan-chart-message")
        |> fill("#budget-input", "250")
        |> assert_text("#this-month-message", "Add a debt")

        refute count(ctx, "#plan-chart canvas") > 0
      end

      # --- retirement -----------------------------------------------------------

      test "retirement: dismissing the banner persists", %{mode: mode} = ctx do
        ctx = start(ctx, mode)

        ctx
        |> assert_selector("#retirement-onboarding-banner")
        |> click("#dismiss-retirement-banner")
        |> refute_selector("#retirement-onboarding-banner")

        ctx = persist(ctx, mode)
        refute_selector(ctx, "#retirement-onboarding-banner")
      end

      test "retirement: Skip for now closes the modal and hides the banner",
           %{mode: mode} = ctx do
        ctx = start(ctx, mode)

        ctx
        |> open_roster()
        |> click("#dismiss-retirement-prompt")
        |> refute_selector("#retirement-modal")
        |> refute_selector("#retirement-onboarding-banner")

        ctx = persist(ctx, mode)
        refute_selector(ctx, "#retirement-onboarding-banner")
      end

      test "retirement: manual profile validation, add, edit, delete", %{mode: mode} = ctx do
        ctx = start(ctx, mode)
        add_visa(ctx, "ZQXRet Visa", "4500")

        ctx
        |> open_roster()
        |> click("#open-add-retirement-profile")
        |> assert_selector("#retirement-profile-form")
        |> click("#retirement-source-manual")
        |> click("#save-retirement-profile")
        |> assert_text("#retirement-profile-form", "can't be blank")
        |> fill("#retirement_profile_name", "ZQXPat")
        |> fill_numbers()
        |> fill("#retirement_profile_retirement_age", "30")
        |> click("#save-retirement-profile")
        |> assert_text("#retirement-profile-form", "must be greater than current age")
        |> fill("#retirement_profile_retirement_age", "65")
        |> fill("#retirement_profile_expected_annual_return_bp", "50")
        |> click("#save-retirement-profile")
        |> assert_text("#retirement-profile-form", "must be less than or equal to 30")
        |> fill("#retirement_profile_expected_annual_return_bp", "7")
        |> click("#save-retirement-profile")
        |> assert_selector("#retirement-profile-list")
        |> assert_text("#retirement-profile-list", "ZQXPat")
        |> assert_text("#retirement-profile-list", "retiring at 65")
        |> click("#close-retirement-modal")
        |> refute_selector("#retirement-onboarding-banner")

        ctx = persist(ctx, mode)
        refute_selector(ctx, "#retirement-onboarding-banner")
        ctx = open_roster_after_reload(ctx)
        assert_text(ctx, "#retirement-profile-list", "ZQXPat")

        id = profile_id(ctx, "ZQXPat")

        ctx
        |> click("#edit-retirement-profile-#{id}")
        |> assert_selector("#retirement-profile-form")
        |> wait_js("document.querySelector('#retirement_profile_name').value === 'ZQXPat'")
        |> wait_js("document.querySelector('#retirement_profile_current_age').value === '35'")
        |> fill("#retirement_profile_current_age", "40")
        |> click("#save-retirement-profile")
        |> assert_text("#retirement-profile-list", "currently 40")

        ctx
        |> click("#delete-retirement-profile-#{id}")
        |> assert_selector("#retirement-empty")

        ctx = persist(ctx, mode)
        ctx = open_roster_after_reload(ctx)
        assert_selector(ctx, "#retirement-empty")
        finish(ctx, mode, ["ZQXPat", "ZQXRet"])
      end

      test "retirement: profile for the existing household member", %{mode: mode} = ctx do
        ctx = start(ctx, mode)

        ctx
        |> open_roster()
        |> click("#open-add-retirement-profile")
        |> assert_selector("#retirement-profile-form")
        |> assert_selector("#retirement_profile_user_id")
        |> fill_numbers()
        |> click("#save-retirement-profile")
        |> assert_selector("#retirement-profile-list")

        name = Accounts.get_default_user!().display_name
        assert_text(ctx, "#retirement-profile-list", name)

        ctx = persist(ctx, mode)
        ctx = open_roster_after_reload(ctx)
        assert_text(ctx, "#retirement-profile-list", name)
      end

      # --- settings / activity / tutorial ---------------------------------------

      test "settings: one Save applies names and currency; an invalid name keeps the modal",
           %{mode: mode} = ctx do
        ctx = start(ctx, mode)

        ctx
        |> click("#settings-button")
        |> fill("#settings-workspace-name", "")
        |> click("#settings-save")
        |> assert_selector("#workspace-name-error")
        |> assert_selector("#settings-modal")
        |> fill("#settings-display-name", "Casey")
        |> fill("#settings-workspace-name", "Casey's Debts")
        |> select("#settings-currency", "EUR")
        |> click("#settings-save")
        |> refute_selector("#settings-modal")
        |> assert_text("#workspace-name", "Casey's Debts")
        |> assert_text("#page-notice-text", "Settings saved.")

        ctx = persist(ctx, mode)
        assert_text(ctx, "#workspace-name", "Casey's Debts")
        ctx = click(ctx, "#settings-button") |> assert_selector("#settings-modal")
        assert eval(ctx, "document.querySelector('#settings-currency').value") == "EUR"
        assert eval(ctx, "document.querySelector('#settings-display-name').value") == "Casey"
      end

      test "the activity log shows entries with amounts in the chosen currency",
           %{mode: mode} = ctx do
        ctx = start(ctx, mode)
        id = add_visa(ctx, "ZQXLog Visa")

        ctx
        |> click("#log-payment-#{id}")
        |> fill("#payment-amount", "123.45")
        |> click("#payment-save")
        |> refute_selector("#payment-modal")
        |> click("#settings-button")
        |> select("#settings-currency", "EUR")
        |> click("#settings-save")
        |> refute_selector("#settings-modal")
        |> click("#activity-log-button")
        |> assert_selector("#activity-log-modal")
        |> assert_text("#activity-log-entries", "ZQXLog Visa")
        |> assert_text("#activity-log-entries", "€123.45")
        |> click("#activity-log-close")
        |> refute_selector("#activity-log-modal")

        finish(ctx, mode, ["ZQXLog"])
      end

      test "'View tutorial again' closes settings and starts the tutorial", %{mode: mode} = ctx do
        ctx = start(ctx, mode)

        ctx
        |> refute_selector("#tutorial-card")
        |> click("#settings-button")
        |> click("#restart-tutorial")
        |> refute_selector("#settings-modal")
        |> assert_selector("#tutorial-card")
        |> click("#tutorial-skip")
        |> refute_selector("#tutorial-card")
      end

      test "the footer is present", %{mode: mode} = ctx do
        ctx = start(ctx, mode)
        assert_selector(ctx, "#footer, footer")
      end
    end
  end

  # --- E2EE-only checks --------------------------------------------------------

  describe "e2ee only" do
    setup do
      {:ok, _} = Accounts.set_tutorial_seen(Accounts.get_default_user!(), true)
      e2ee_on(hook: false)
      :ok
    end

    test "settings: CSV export is built in the browser, identical to the data", ctx do
      ctx = start(ctx, :e2ee)
      id = add_visa(ctx, "ZQXCsv, \"Visa\"")

      ctx
      |> click("#log-payment-#{id}")
      |> fill("#payment-amount", "10")
      |> fill("#payment-note", "=SUM(A1), \"quoted\"\nline2")
      |> click("#payment-save")
      |> refute_selector("#payment-modal")

      js(ctx, """
      (() => { window.__csv = []; const o = URL.createObjectURL.bind(URL);
        URL.createObjectURL = (b) => { b.text().then((t) => window.__csv.push(t)); return o(b); }; })()
      """)

      ctx
      |> click("#settings-button")
      |> refute_selector("a#export-debts")
      |> assert_selector("button#export-debts")

      # DOM clicks: Playwright's own click waits on the download "navigation".
      js(ctx, "document.querySelector('#export-debts').click()")
      wait_js(ctx, "window.__csv.length === 1")
      js(ctx, "document.querySelector('#export-payments').click()")
      wait_js(ctx, "window.__csv.length === 2")

      [debts, payments] = js(ctx, "window.__csv")
      assert debts =~ "Name,Type,Balance,APR,Status"
      assert debts =~ ~s("ZQXCsv, ""Visa""",revolving,990.00,20.00,active)
      assert payments =~ "Debt,Amount,Principal Portion,Interest Portion,Paid On,Note"
      assert payments =~ "\"=SUM(A1), \"\"quoted\"\"\nline2\""
      assert errors(ctx) == []
      finish(ctx, :e2ee, ["ZQXCsv"])
    end

    test "a full flow leaves no marker in the server log, DB, cookies or browser storage",
         ctx do
      markers = ["ZQXLogDebt", "ZQXLogNote"]

      log =
        ExUnit.CaptureLog.capture_log([level: :debug], fn ->
          ctx = start(ctx, :e2ee)
          id = add_visa(ctx, "ZQXLogDebt")

          ctx
          |> click("#log-payment-#{id}")
          |> fill("#payment-amount", "10")
          |> fill("#payment-note", "ZQXLogNote")
          |> click("#payment-save")
          |> refute_selector("#payment-modal")

          persist(ctx, :e2ee)
          finish(ctx, :e2ee, markers)
          dump = JSON.encode!(storage_dump(ctx)) <> JSON.encode!(cookies(ctx))
          for m <- markers, do: refute(dump =~ m, "#{m} in browser storage or cookies")
        end)

      for m <- markers, do: refute(log =~ m, "#{m} in the server log")
    end

    test "settings: sharing is replaced by an explanation", ctx do
      ctx = start(ctx, :e2ee)
      ctx |> click("#settings-button") |> assert_selector("#settings-modal")
      refute_selector(ctx, "#settings-share-form")
    end
  end

  describe "e2ee auto-logged installments (hook)" do
    setup do
      {:ok, _} = Accounts.set_tutorial_seen(Accounts.get_default_user!(), true)
      e2ee_on(hook: true)
      :ok
    end

    test "two tabs opening the vault together post the missed cycles once", ctx do
      ctx_a = open_app(ctx)
      {ctx_a, _} = create_vault(ctx_a, @pass)
      click(ctx_a, "#test-hook-add-auto")
      assert_text(ctx_a, "#vault-debts", "Auto loan")
      wait_js(ctx_a, "document.querySelector('#vault-sync-status')?.dataset.status === 'saved'")
      assert text(ctx_a, "#vault-payments-count") =~ "0 payments"

      ctx_b = new_tab(ctx, "b")
      ctx_a = lock(ctx_a)

      # both tabs unlock at once; each runs the catch-up on its own copy
      unlock_with_passphrase(ctx_a, @pass)
      unlock_with_passphrase(ctx_b, @pass)
      assert_selector(ctx_a, "#vault-home")
      assert_selector(ctx_b, "#vault-home")

      wait_js(
        ctx_a,
        "!document.querySelector('#vault-payments-count').innerText.startsWith('0 ')"
      )

      Process.sleep(2500)

      for c <- [ctx_a, ctx_b] do
        wait_js(
          c,
          "['saved','idle','merged'].includes(document.querySelector('#vault-sync-status')?.dataset.status)"
        )
      end

      posted = text(ctx_a, "#vault-payments-count")

      # a fresh open sees exactly the cycles once (deterministic ids merged them)
      ctx_a = ctx_a |> lock() |> unlock_with_passphrase_ctx()
      assert_text(ctx_a, "#vault-payments-count", posted)
      assert_text(ctx_a, "#debt-sidebar", "Auto loan")
    end
  end

  describe "e2ee performance (hook)" do
    setup do
      {:ok, _} = Accounts.set_tutorial_seen(Accounts.get_default_user!(), true)
      e2ee_on(hook: true)
      :ok
    end

    @tag skip: if(System.get_env("E2EE_PERF"), do: false, else: "set E2EE_PERF=1 (takes ~4 min)")
    @tag timeout: 900_000
    @tag ownership_timeout: 900_000
    test "a workspace with 500 payments: timings of an ordinary action", ctx do
      ctx = open_app(ctx)
      {ctx, _} = create_vault(ctx, @pass)
      # a $1,000 debt takes 99 payments of $10: six debts for 500+
      for n <- 1..6, do: add_debt(ctx, "ZQXBig #{n}")

      ids =
        js(ctx, "Array.from(document.querySelectorAll('.vault-debt')).map(e => e.id.slice(11))")

      # 500 payments through the real ledger path (one click each, 10 at a time)
      {load_ms, _} =
        :timer.tc(fn ->
          for batch <- 1..50 do
            id = Enum.at(ids, div(batch - 1, 10))

            {ms, _} =
              :timer.tc(fn ->
                js(
                  ctx,
                  "for (let i = 0; i < 10; i++) document.querySelector('#vault-pay-#{id}').click()"
                )

                wait_js(
                  ctx,
                  "document.querySelector('#vault-payments-count').innerText.startsWith('#{batch * 10} ')",
                  1500
                )
              end)

            if rem(batch, 5) == 0,
              do:
                IO.puts(
                  "[perf] payments=#{batch * 10}: 10 actions took #{div(ms, 1000)} ms; " <>
                    "last ledger apply #{attr(ctx, "#vault-perf", "data-apply-ms")} ms, view #{attr(ctx, "#vault-perf", "data-view-ms")} ms"
                )
          end
        end)

      wait_js(ctx, "document.querySelector('#vault-sync-status').dataset.status === 'saved'", 600)

      # one more ordinary action: UI update (ledger + view), then encrypted save
      id = List.last(ids)

      js(
        ctx,
        "window.__t0 = performance.now(); document.querySelector('#vault-pay-#{id}').click()"
      )

      wait_js(
        ctx,
        "document.querySelector('#vault-payments-count').innerText.startsWith('501 ')",
        300
      )

      apply_ms = js(ctx, "Math.round(performance.now() - window.__t0)")

      wait_js(ctx, "document.querySelector('#vault-sync-status').dataset.status === 'saved'", 600)
      save_ms = js(ctx, "Math.round(performance.now() - window.__t0)")

      # a full reopen: fetch + decrypt + decode + catch-up + render
      ctx = lock(ctx)
      js(ctx, "window.__t1 = performance.now()")
      unlock_with_passphrase(ctx, @pass)
      assert_text(ctx, "#vault-payments-count", "501 payments")
      reopen_ms = js(ctx, "Math.round(performance.now() - window.__t1)")

      IO.puts(
        "\n[perf] 500 payments via the ledger: #{div(load_ms, 1000)} s total; " <>
          "one more payment: UI #{apply_ms} ms, saved #{save_ms} ms; unlock+render #{reopen_ms} ms (incl. KDF)"
      )

      assert apply_ms < 5000
      assert errors(ctx) == []
    end
  end

  # --- helpers -------------------------------------------------------------------

  defp unlock_with_passphrase_ctx(ctx) do
    unlock_with_passphrase(ctx, @pass)
    ctx
  end

  defp start(ctx, :plain),
    do: visit_page(ctx, DashboardPage) |> assert_selector("#add-debt-button")

  defp start(ctx, :e2ee) do
    ctx = open_app(ctx)
    {ctx, _key} = create_vault(ctx, @pass)
    assert_selector(ctx, "#add-debt-button")
  end

  # Waits until the change is saved (E2EE), reloads, and unlocks again.
  defp persist(ctx, :plain), do: reload(ctx) |> assert_selector("#add-debt-button")

  defp persist(ctx, :e2ee) do
    wait_js(
      ctx,
      "['saved','idle','merged'].includes(document.querySelector('#vault-sync-status')?.dataset.status)"
    )

    ctx = reload(ctx)
    unlock_with_passphrase(ctx, @pass)
    assert_selector(ctx, "#add-debt-button")
  end

  defp finish(ctx, :plain, _markers), do: ctx

  defp finish(ctx, :e2ee, markers) do
    wait_js(
      ctx,
      "['saved','idle','merged'].includes(document.querySelector('#vault-sync-status')?.dataset.status)"
    )

    refute_in_database(markers)
    assert errors(ctx) == []
    ctx
  end

  defp debt_id(ctx, name) do
    js(
      ctx,
      "Array.from(document.querySelectorAll('#debt-list li')).find(li => li.textContent.includes(#{JSON.encode!(name)}))?.id.slice(5)"
    )
  end

  defp add_visa(ctx, name, balance \\ "1000") do
    ctx
    |> click("#add-debt-button")
    |> assert_selector("#debt-form-modal")
    |> fill("#debt-name", name)
    |> select("#debt-type", "revolving")
    |> fill("#debt-balance", balance)
    |> fill("#debt-apr", "20")
    |> fill("#debt-minimum-payment-floor", "35")
    |> fill("#debt-minimum-payment-rate", "0.02")
    |> fill("#debt-credit-limit", "5000")
    |> click("#debt-form-save")
    |> refute_selector("#debt-form-modal")
    |> assert_text("#debt-list", name)

    wait_js(
      ctx,
      "!!Array.from(document.querySelectorAll('#debt-list li')).find(li => li.textContent.includes(#{JSON.encode!(name)}))"
    )

    debt_id(ctx, name)
  end

  defp add_loan(ctx, name, mode \\ "off") do
    ctx =
      ctx
      |> click("#add-debt-button")
      |> assert_selector("#debt-form-modal")
      |> fill("#debt-name", name)
      |> select("#debt-type", "installment")
      |> fill("#debt-balance", "8000")
      |> fill("#debt-apr", "6")
      |> fill("#debt-fixed-payment", "250")
      |> select("#debt-auto-log-mode", mode)

    ctx = if mode == "off", do: ctx, else: fill(ctx, "#debt-due-day", "1")

    ctx
    |> click("#debt-form-save")
    |> refute_selector("#debt-form-modal")
    |> assert_text("#debt-list", name)

    debt_id(ctx, name)
  end

  defp open_roster(ctx) do
    ctx
    |> click("#open-retirement-onboarding")
    |> assert_selector("#retirement-modal")
  end

  # After a reload the banner is gone once a profile exists: use the settings entry.
  defp open_roster_after_reload(ctx) do
    ctx
    |> click("#settings-button")
    |> click("#open-retirement")
    |> assert_selector("#retirement-modal")
  end

  defp profile_id(ctx, name) do
    js(
      ctx,
      "Array.from(document.querySelectorAll('#retirement-profile-list li')).find(li => li.textContent.includes(#{JSON.encode!(name)}))?.id.slice(" <>
        "#{String.length("retirement-profile-")})"
    )
  end

  defp fill_numbers(ctx) do
    ctx
    |> fill("#retirement_profile_current_age", "35")
    |> fill("#retirement_profile_retirement_age", "65")
    |> fill("#retirement_profile_current_retirement_savings", "50000")
    |> fill("#retirement_profile_monthly_retirement_contribution", "500")
    |> fill("#retirement_profile_monthly_gross_income", "6000")
    |> fill("#retirement_profile_post_debt_investment_bp", "15")
    |> fill("#retirement_profile_expected_annual_return_bp", "7")
  end
end
