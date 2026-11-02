defmodule DebtReliefTrackerWeb.PageControllerTest do
  use DebtReliefTrackerWeb.ConnCase

  test "GET / redirects to the Hologram dashboard at /app", %{conn: conn} do
    conn = get(conn, "/")
    assert redirected_to(conn, 302) == "/app"
  end

  test "GET / drops the query string", %{conn: conn} do
    conn = get(conn, "/?x=1")
    assert redirected_to(conn) == "/app"
  end
end
