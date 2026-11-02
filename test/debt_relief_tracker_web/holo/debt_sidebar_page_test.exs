defmodule DebtReliefTrackerWeb.Holo.DebtSidebarPageTest do
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
        "minimum_payment_rate" => "0.02",
        "credit_limit" => "10000.00"
      })

    :ok
  end

  test "GET / renders the debt rail with the seeded debt", %{conn: conn} do
    html = conn |> get("/") |> html_response(200)
    doc = LazyHTML.from_document(html)

    assert LazyHTML.query(doc, "#add-debt-button") |> Enum.count() == 1
    assert LazyHTML.query(doc, "#log-all-balances-button") |> Enum.count() == 1
    assert LazyHTML.query(doc, "#activity-log-button") |> Enum.count() == 1
    assert LazyHTML.query(doc, "#debt-list") |> Enum.count() == 1

    list = LazyHTML.query(doc, "#debt-list")
    text = LazyHTML.text(list)
    assert text =~ "Visa"
    assert text =~ "$4,500.00"
    assert text =~ "45% utilization"
    assert text =~ "Log payment"
    assert text =~ "Mark paid"
  end
end
