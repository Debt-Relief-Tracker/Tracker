defmodule DebtReliefTrackerWeb.DashboardLiveOidcTest do
  @moduledoc """
  Exercises DashboardLive's session-driven login gate and workspace
  resolution when OIDC is "configured" (docs/architecture/0002-auth-and-sharing-model.md).
  The actual provider redirect/token exchange isn't testable without a real
  IdP (see AuthControllerTest) -- this covers everything downstream of a
  session that already has a `user_id`, which is the part the rest of the
  app (DashboardLive) actually depends on.
  """

  use DebtReliefTrackerWeb.ConnCase

  import Phoenix.LiveViewTest

  alias DebtReliefTracker.Accounts

  setup do
    Application.put_env(:debt_relief_tracker, :oidc,
      issuer: "https://idp.example.com",
      client_id: "test-client",
      client_secret: "test-secret"
    )

    on_exit(fn -> Application.put_env(:debt_relief_tracker, :oidc, nil) end)
    :ok
  end

  test "redirects to /auth/login when there's no session user", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/auth/login"}}} = live(conn, ~p"/")
  end

  test "mounts the logged-in user's own workspace when the session has a user_id", %{conn: conn} do
    user =
      Accounts.get_or_create_user_from_oidc!(%{
        "sub" => "a",
        "email" => "a@example.com",
        "name" => "Alex"
      })

    conn = Plug.Test.init_test_session(conn, user_id: user.id)

    {:ok, view, html} = live(conn, ~p"/")

    assert html =~ "Alex"
    assert html =~ "Alex&#39;s Debts"
    refute has_element?(view, "select[name=workspace_id]")
    assert has_element?(view, "input[name='share[email]']")
  end

  test "shows a workspace switcher once the user has more than one workspace, and gates sharing on ownership of the *current* one",
       %{conn: conn} do
    owner =
      Accounts.get_or_create_user_from_oidc!(%{
        "sub" => "owner",
        "email" => "owner@example.com",
        "name" => "Owner"
      })

    member =
      Accounts.get_or_create_user_from_oidc!(%{
        "sub" => "member",
        "email" => "member@example.com",
        "name" => "Member"
      })

    owner_workspace = Accounts.current_workspace_for_user(owner)
    {:ok, _} = Accounts.share_workspace_with_email(owner_workspace, "member@example.com")

    conn = Plug.Test.init_test_session(conn, user_id: member.id)
    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "select[name=workspace_id]")
    # Defaults to member's own workspace, which they own -- sharing shows.
    assert has_element?(view, "input[name='share[email]']")

    html =
      view
      |> form("form[phx-change=switch_workspace]", %{"workspace_id" => owner_workspace.id})
      |> render_change()

    assert html =~ "Owner&#39;s Debts"
    # Now viewing a workspace they don't own -- sharing hides.
    refute has_element?(view, "input[name='share[email]']")
  end

  test "switching workspace picks up the target workspace's own currency", %{conn: conn} do
    member =
      Accounts.get_or_create_user_from_oidc!(%{
        "sub" => "member",
        "email" => "member@example.com",
        "name" => "Member"
      })

    owner =
      Accounts.get_or_create_user_from_oidc!(%{
        "sub" => "owner",
        "email" => "owner@example.com",
        "name" => "Owner"
      })

    owner_workspace = Accounts.current_workspace_for_user(owner)
    {:ok, _} = Accounts.share_workspace_with_email(owner_workspace, "member@example.com")

    owner_settings = DebtReliefTracker.Settings.get_settings!(owner_workspace)
    {:ok, _} = DebtReliefTracker.Settings.update_settings(owner_settings, %{"currency" => "GBP"})

    {:ok, _debt} =
      DebtReliefTracker.Debts.create_debt(owner_workspace, nil, %{
        "name" => "Owner's Card",
        "type" => "installment",
        "balance" => "100.00",
        "apr" => "1.00",
        "fixed_payment" => "10.00"
      })

    conn = Plug.Test.init_test_session(conn, user_id: member.id)
    {:ok, view, _html} = live(conn, ~p"/")

    html =
      view
      |> form("form[phx-change=switch_workspace]", %{"workspace_id" => owner_workspace.id})
      |> render_change()

    assert html =~ "£100.00"
  end
end
