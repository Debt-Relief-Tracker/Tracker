defmodule DebtReliefTrackerWeb.AuthControllerTest do
  use DebtReliefTrackerWeb.ConnCase

  # The actual OIDC redirect/token-exchange flow needs a real provider to
  # test end-to-end (docs/architecture/0002-auth-and-sharing-model.md) --
  # not available in this environment. What's covered here is everything
  # that doesn't require one: the routes exist and no-op safely when OIDC
  # isn't configured (the default), and logout works regardless.

  test "GET /auth/login redirects back to \"/\" when OIDC isn't configured", %{conn: conn} do
    conn = get(conn, ~p"/auth/login")
    assert redirected_to(conn) == ~p"/"
  end

  test "GET /auth/callback with no session_params redirects to \"/\" with an error", %{conn: conn} do
    conn = get(conn, ~p"/auth/callback", %{})
    assert redirected_to(conn) == ~p"/"
    assert Phoenix.Flash.get(conn.assigns.flash, :error)
  end

  test "POST /auth/logout clears the session and redirects to \"/\"", %{conn: conn} do
    conn = conn |> Plug.Test.init_test_session(user_id: 123) |> post(~p"/auth/logout")
    assert redirected_to(conn) == ~p"/"

    # configure_session(drop: true) finalizes the cleared session into the
    # response cookie -- recycle to simulate the browser's next request
    # carrying that cookie, then confirm it's really gone.
    conn = conn |> recycle() |> get(~p"/")
    assert get_session(conn, :user_id) == nil
  end

  test "POST /auth/logout redirects to Auth0's logout endpoint and still clears the session when OIDC is configured",
       %{conn: conn} do
    Application.put_env(:debt_relief_tracker, :oidc,
      issuer: "https://idp.example.com",
      client_id: "test-client",
      client_secret: "test-secret"
    )

    on_exit(fn -> Application.put_env(:debt_relief_tracker, :oidc, nil) end)

    conn = conn |> Plug.Test.init_test_session(user_id: 123) |> post(~p"/auth/logout")

    location = conn |> Plug.Conn.get_resp_header("location") |> List.first()
    assert location =~ "https://idp.example.com/v2/logout?"
    assert location =~ "client_id=test-client"

    conn = conn |> recycle() |> get(~p"/")
    assert get_session(conn, :user_id) == nil
  end
end
