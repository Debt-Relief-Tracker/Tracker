defmodule DebtReliefTrackerWeb.Holo.DashboardPageBrowserTest do
  # Real-browser smoke tests. Excluded from `mix test`; run with
  # `mix test --include browser` (see docs/holo-ui-conventions.md).
  use DebtReliefTracker.BrowserCase

  alias DebtReliefTracker.{Accounts, Debts}
  alias DebtReliefTracker.BrowserCase.CounterPage
  alias DebtReliefTrackerWeb.Holo.DashboardPage

  test "/app mounts and shows the dashboard and this-month card", ctx do
    ctx
    |> visit_page(DashboardPage)
    |> assert_selector("#holo-dashboard")
    |> assert_selector("#this-month-card")

    assert current_path(ctx) == "/app"
  end

  test "a seeded debt is named in the this-month card", ctx do
    workspace = Accounts.ensure_default_workspace!()

    {:ok, _} =
      Debts.create_debt(workspace, nil, %{
        "name" => "Browser Visa",
        "type" => "revolving",
        "balance" => "4500.00",
        "apr" => "24.99",
        "minimum_payment_floor" => "35.00",
        "minimum_payment_rate" => "0.02"
      })

    ctx
    |> visit_page(DashboardPage)
    |> assert_text("#this-month-card", "Browser Visa")
  end

  test "client-side clicks run actions and re-render (test-only page)", ctx do
    ctx
    |> visit_page(CounterPage)
    |> assert_text("#count", "Count: 0")
    |> click("#increment")
    |> click("#increment")
    |> assert_text("#count", "Count: 2")
    |> refute_selector("#demo-modal")
    |> click("#open-modal")
    |> assert_selector("#demo-modal")
    |> click("#close-modal")
    |> refute_selector("#demo-modal")
  end
end
