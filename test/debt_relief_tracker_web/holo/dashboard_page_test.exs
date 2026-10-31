defmodule DebtReliefTrackerWeb.Holo.DashboardPageTest do
  use DebtReliefTrackerWeb.ConnCase

  alias DebtReliefTracker.{Accounts, Debts}

  setup do
    workspace = Accounts.ensure_default_workspace!()

    {:ok, _} =
      Debts.create_debt(workspace, nil, %{
        "name" => "Visa",
        "type" => "revolving",
        "balance" => "4500.00",
        "apr" => "24.99",
        "minimum_payment_floor" => "35.00",
        "minimum_payment_rate" => "0.02"
      })

    :ok
  end

  test "GET /app renders the dashboard shell and this-month card", %{conn: conn} do
    html = conn |> get("/app") |> html_response(200)
    doc = LazyHTML.from_document(html)

    assert LazyHTML.query(doc, "#holo-dashboard") |> Enum.count() == 1
    assert LazyHTML.query(doc, "#this-month-card") |> LazyHTML.text() =~ "Visa"
  end
end
