defmodule DebtReliefTrackerWeb.Holo.ChromeBrowserTest do
  # Real-browser tests of the /app chrome (header, settings modal, activity
  # log) in no-auth mode. OIDC-only flows live in ChromeOidcBrowserTest.
  use DebtReliefTracker.BrowserCase

  alias DebtReliefTracker.{Accounts, Debts, Payments, Settings}
  alias DebtReliefTrackerWeb.Holo.DashboardPage

  # A fresh user would get the tutorial overlay, which covers the page.
  setup do
    {:ok, _} = Accounts.set_tutorial_seen(Accounts.get_default_user!(), true)
    :ok
  end

  defp open_settings(ctx) do
    ctx |> click("#settings-button") |> assert_selector("#settings-modal")
  end

  test "settings modal opens, closes with Cancel, Escape and outside click", ctx do
    ctx
    |> visit_page(DashboardPage)
    |> open_settings()
    |> click("#settings-cancel")
    |> refute_selector("#settings-modal")
    |> open_settings()
    |> press("Escape")
    |> refute_selector("#settings-modal")
    |> open_settings()
    |> click_at("#settings-modal", 3, 3)
    |> refute_selector("#settings-modal")
  end

  test "one Save applies display name, tracker name and currency and shows a notice", ctx do
    workspace = Accounts.ensure_default_workspace!()

    ctx
    |> visit_page(DashboardPage)
    |> open_settings()
    |> fill("#settings-display-name", "Casey")
    |> fill("#settings-workspace-name", "Casey's Debts")
    |> select("#settings-currency", "EUR")
    |> click("#settings-save")
    |> refute_selector("#settings-modal")
    |> assert_text("#workspace-name", "Casey's Debts")
    |> assert_text("#page-notice-text", "Settings saved.")

    assert Accounts.get_workspace!(workspace.id).name == "Casey's Debts"
    assert Accounts.get_default_user!().display_name == "Casey"
    assert Settings.get_settings!(workspace).currency == "EUR"

    # Re-opening shows the saved values (and clears the notice).
    ctx
    |> open_settings()
    |> refute_selector("#page-notice")

    assert eval(ctx, "document.querySelector('#settings-workspace-name').value") == "Casey's Debts"
    assert eval(ctx, "document.querySelector('#settings-currency').value") == "EUR"
  end

  test "an invalid tracker name shows an inline error and keeps the modal open", ctx do
    ctx
    |> visit_page(DashboardPage)
    |> open_settings()
    |> fill("#settings-workspace-name", "")
    |> click("#settings-save")
    |> assert_selector("#workspace-name-error")
    |> assert_selector("#settings-modal")
  end

  test "theme toggle applies data-theme, persists to localStorage and the account", ctx do
    user = Accounts.get_default_user!()

    ctx
    |> visit_page(DashboardPage)
    |> click("#theme-dark")
    |> wait_for_expr("document.documentElement.getAttribute('data-theme') === 'dark'")

    assert eval(ctx, "localStorage.getItem('phx:theme')") == "dark"
    wait_for_expr(ctx, "document.querySelector('#app-header').dataset.savedTheme === 'dark'")
    assert to_string(Accounts.get_user!(user.id).preferences.theme) == "dark"

    # A reload keeps it, from the account as well as the device.
    ctx
    |> visit_page(DashboardPage)
    |> wait_for_expr("document.documentElement.getAttribute('data-theme') === 'dark'")
    |> click("#theme-light")
    |> wait_for_expr("document.documentElement.getAttribute('data-theme') === 'light'")
    |> click("#theme-system")
    |> wait_for_expr("!document.documentElement.hasAttribute('data-theme')")

    assert eval(ctx, "localStorage.getItem('phx:theme')") == nil
  end

  test "the account theme wins over a stale device theme on load", ctx do
    user = Accounts.get_default_user!()
    {:ok, _} = Accounts.update_preferences(user, %{theme: "dark"})

    ctx
    |> visit_page(DashboardPage)
    |> wait_for_expr("document.documentElement.getAttribute('data-theme') === 'dark'")
  end

  test "CSV export links respond with CSV", ctx do
    workspace = Accounts.ensure_default_workspace!()
    seed_debt(workspace, "Export Visa")

    ctx |> visit_page(DashboardPage) |> open_settings()

    for {id, path} <- [
          {"#export-debts", "/export/debts.csv"},
          {"#export-payments", "/export/payments.csv"}
        ] do
      assert attr(ctx, id, "href") == path

      result =
        eval(ctx, """
        fetch('#{path}').then(async r => ({status: r.status, type: r.headers.get('content-type'), body: await r.text()}))
        """)

      assert result["status"] == 200
      assert result["type"] =~ "csv"
    end
  end

  test "'View tutorial again' closes settings and starts the tutorial overlay", ctx do
    ctx
    |> visit_page(DashboardPage)
    |> refute_selector("#tutorial-card")
    |> open_settings()
    |> click("#restart-tutorial")
    |> refute_selector("#settings-modal")
    |> assert_selector("#tutorial-card")

    click(ctx, "#tutorial-skip")
    refute_selector(ctx, "#tutorial-card")
  end

  test "the activity log renders entries with amounts in the chosen currency", ctx do
    workspace = Accounts.ensure_default_workspace!()
    debt = seed_debt(workspace, "Log Visa")

    {:ok, _} =
      Payments.log_payment(workspace, nil, debt, %{
        "amount" => "123.45",
        "paid_on" => Date.to_iso8601(Date.utc_today())
      })

    {:ok, _} =
      Settings.update_settings(Settings.get_settings!(workspace), %{currency: "EUR"})

    ctx
    |> visit_page(DashboardPage)
    |> click("#activity-log-button")
    |> assert_selector("#activity-log-modal")
    |> assert_text("#activity-log-entries", "Log Visa")
    |> assert_text("#activity-log-entries", "€123.45")
    |> click("#activity-log-close")
    |> refute_selector("#activity-log-modal")
  end

  defp seed_debt(workspace, name) do
    {:ok, debt} =
      Debts.create_debt(workspace, nil, %{
        "name" => name,
        "type" => "revolving",
        "balance" => "4500.00",
        "apr" => "24.99",
        "minimum_payment_floor" => "35.00",
        "minimum_payment_rate" => "0.02"
      })

    debt
  end
end
