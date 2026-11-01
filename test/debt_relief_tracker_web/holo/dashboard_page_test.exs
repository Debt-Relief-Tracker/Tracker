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

  test "GET /app renders the footer with the donate modal links and admin link", %{conn: conn} do
    doc = conn |> get("/app") |> html_response(200) |> LazyHTML.from_document()

    assert LazyHTML.query(doc, "#app-footer #donate-link") |> Enum.count() == 1
    assert LazyHTML.query(doc, "#donate-modal.hidden") |> Enum.count() == 1
    assert LazyHTML.query(doc, ~s(#donate-modal a#donate-liberapay[href="https://liberapay.com/DebtReliefTracker/"])) |> Enum.count() == 1
    assert LazyHTML.query(doc, ~s(#donate-modal a#donate-ko-fi[href="https://ko-fi.com/calonmerc"])) |> Enum.count() == 1
    assert LazyHTML.query(doc, "#donate-modal div#donate-github-sponsors") |> Enum.count() == 1
    assert LazyHTML.query(doc, "#donate-modal a#donate-github-sponsors") |> Enum.count() == 0
    # no-auth mode is fully trusted
    assert LazyHTML.query(doc, ~s(#app-footer a[href="/admin"])) |> Enum.count() == 1
  end

  test "GET /app does not server-render the tutorial overlay open", %{conn: conn} do
    doc = conn |> get("/app") |> html_response(200) |> LazyHTML.from_document()
    assert LazyHTML.query(doc, "#tutorial-overlay") |> Enum.count() == 1
    assert LazyHTML.query(doc, "#tutorial-card") |> Enum.count() == 0
  end
end
