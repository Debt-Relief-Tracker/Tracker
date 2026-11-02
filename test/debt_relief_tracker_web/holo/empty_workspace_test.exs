defmodule DebtReliefTrackerWeb.Holo.EmptyWorkspaceTest do
  use DebtReliefTrackerWeb.ConnCase

  test "GET /app renders for a workspace with no debts", %{conn: conn} do
    html = conn |> get("/app") |> html_response(200)
    doc = LazyHTML.from_document(html)

    assert LazyHTML.query(doc, "#holo-dashboard") |> Enum.count() == 1
    assert LazyHTML.query(doc, "#debt-list") |> Enum.count() == 1
  end
end
