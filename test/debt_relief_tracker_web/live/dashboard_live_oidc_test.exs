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
  import Swoosh.TestAssertions

  alias DebtReliefTracker.Accounts

  setup do
    Application.put_env(:debt_relief_tracker, :oidc,
      issuer: "https://idp.example.com",
      client_id: "test-client",
      client_secret: "test-secret"
    )

    # Emails triggered by handle_event (e.g. share_workspace) are sent from
    # the LiveView's own process, not this test process, so Swoosh.Adapters.Test
    # (which sends to `self()`/`$callers`) would otherwise deliver nowhere.
    # This module isn't async, so it's safe to point it at this test process.
    Application.put_env(:swoosh, :shared_test_process, self())

    on_exit(fn ->
      Application.put_env(:debt_relief_tracker, :oidc, nil)
      Application.delete_env(:swoosh, :shared_test_process)
    end)

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

    view |> element("button[phx-click=open_settings]") |> render_click()
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
    {:ok, _} = Accounts.share_workspace_with_email(owner_workspace, "member@example.com", owner)

    conn = Plug.Test.init_test_session(conn, user_id: member.id)
    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "select[name=workspace_id]")

    # Defaults to member's own workspace, which they own -- sharing shows.
    view |> element("button[phx-click=open_settings]") |> render_click()
    assert has_element?(view, "input[name='share[email]']")
    view |> element("button[phx-click=close_modal]") |> render_click()

    html =
      view
      |> form("form[phx-change=switch_workspace]", %{"workspace_id" => owner_workspace.id})
      |> render_change()

    assert html =~ "Owner&#39;s Debts"

    # Now viewing a workspace they don't own -- sharing hides.
    view |> element("button[phx-click=open_settings]") |> render_click()
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
    {:ok, _} = Accounts.share_workspace_with_email(owner_workspace, "member@example.com", owner)

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

  test "inviting an unknown email shows a pending badge that can be canceled", %{conn: conn} do
    owner =
      Accounts.get_or_create_user_from_oidc!(%{
        "sub" => "owner",
        "email" => "owner@example.com",
        "name" => "Owner"
      })

    conn = Plug.Test.init_test_session(conn, user_id: owner.id)
    {:ok, view, _html} = live(conn, ~p"/")

    view |> element("button[phx-click=open_settings]") |> render_click()

    html =
      view
      |> form("#settings-share-form", %{"share" => %{"email" => "new@example.com"}})
      |> render_submit()

    assert html =~ "Invited new@example.com"
    assert has_element?(view, "span", "new@example.com")

    view
    |> element("button[phx-click=cancel_invitation]")
    |> render_click()

    refute has_element?(view, "span", "new@example.com")
  end

  test "a non-owner member sees the tracker name and currency as read-only, with no People section",
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
    {:ok, _} = Accounts.share_workspace_with_email(owner_workspace, "member@example.com", owner)

    conn = Plug.Test.init_test_session(conn, user_id: member.id)
    {:ok, view, _html} = live(conn, ~p"/")

    view
    |> form("form[phx-change=switch_workspace]", %{"workspace_id" => owner_workspace.id})
    |> render_change()

    view |> element("button[phx-click=open_settings]") |> render_click()

    refute has_element?(view, "#workspace-name-form")
    refute has_element?(view, "select[name=currency]")
    refute has_element?(view, "input[name='share[email]']")

    # Defense-in-depth: crafted rename/currency submissions are server-side no-ops.
    view
    |> render_hook("update_workspace_name", %{"workspace" => %{"name" => "Hijacked"}})

    assert Accounts.get_workspace!(owner_workspace.id).name == owner_workspace.name

    view |> render_hook("select_currency", %{"currency" => "JPY"})

    assert DebtReliefTracker.Settings.get_settings!(owner_workspace).currency !=
             "JPY"
  end

  test "owner renames the workspace and a subsequent invite email reflects the new name", %{
    conn: conn
  } do
    owner =
      Accounts.get_or_create_user_from_oidc!(%{
        "sub" => "owner",
        "email" => "owner@example.com",
        "name" => "Owner"
      })

    conn = Plug.Test.init_test_session(conn, user_id: owner.id)
    {:ok, view, _html} = live(conn, ~p"/")

    view |> element("button[phx-click=open_settings]") |> render_click()

    view
    |> form("#workspace-name-form", %{"workspace" => %{"name" => "Our Debts"}})
    |> render_submit()

    view
    |> form("#settings-share-form", %{"share" => %{"email" => "new@example.com"}})
    |> render_submit()

    assert_email_sent(subject: "You've been invited to Our Debts")
  end

  test "owner sees pending and accepted people, and can remove an accepted member", %{conn: conn} do
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
    {:ok, _} = Accounts.share_workspace_with_email(owner_workspace, "member@example.com", owner)

    conn = Plug.Test.init_test_session(conn, user_id: owner.id)
    {:ok, view, _html} = live(conn, ~p"/")

    view |> element("button[phx-click=open_settings]") |> render_click()

    view
    |> form("#settings-share-form", %{"share" => %{"email" => "new@example.com"}})
    |> render_submit()

    assert has_element?(view, "span", "new@example.com")
    assert has_element?(view, "span", "Member")

    view
    |> element("button[phx-click=remove_member]")
    |> render_click()

    refute has_element?(view, "span", "Member")
    refute owner_workspace in Accounts.list_workspaces_for_user(member)
  end
end
