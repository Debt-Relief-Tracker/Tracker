defmodule DebtReliefTrackerWeb.Holo.CutoverGapsTest do
  @moduledoc """
  Behaviors the LiveView dashboard tests (dashboard_live_oidc_test.exs) covered
  that had no equivalent against the Hologram dashboard page. See
  docs/cutover-test-coverage.md.
  """
  # Not async: OIDC / Auth0 config, Swoosh and Req.Test sharing are global.
  use DebtReliefTrackerWeb.ConnCase

  import Swoosh.TestAssertions

  alias DebtReliefTracker.{Accounts, Settings}
  alias DebtReliefTrackerWeb.Holo.AccountOps

  setup do
    Application.put_env(:debt_relief_tracker, :oidc,
      issuer: "https://idp.example.com",
      client_id: "test-client",
      client_secret: "test-secret"
    )

    Application.put_env(:swoosh, :shared_test_process, self())

    on_exit(fn ->
      Application.put_env(:debt_relief_tracker, :oidc, nil)
      Application.put_env(:debt_relief_tracker, :auth0_management, nil)
      Application.delete_env(:swoosh, :shared_test_process)
    end)

    :ok
  end

  defp oidc_user(sub, name) do
    Accounts.get_or_create_user_from_oidc!(%{
      "sub" => sub,
      "email" => "#{sub}@example.com",
      "name" => name
    })
  end

  defp add_debt(workspace) do
    {:ok, _} =
      DebtReliefTracker.Debts.create_debt(workspace, nil, %{
        "name" => "Owner's Card",
        "type" => "installment",
        "balance" => "100.00",
        "apr" => "1.00",
        "fixed_payment" => "10.00"
      })
  end

  defp enable_auth0_management do
    Application.put_env(:debt_relief_tracker, :auth0_management,
      client_id: "m2m-id",
      client_secret: "m2m-secret",
      domain: "https://tenant.example.auth0.com"
    )
  end

  test "GET / without a session redirects to /auth/login when OIDC is configured", %{
    conn: conn
  } do
    conn = get(conn, "/")
    assert redirected_to(conn) == "/auth/login"
  end

  test "GET / mounts the signed-in user's own workspace, with no switcher", %{conn: conn} do
    user = oidc_user("a", "Alex")

    doc =
      conn
      |> Plug.Test.init_test_session(user_id: user.id)
      |> get("/")
      |> html_response(200)
      |> LazyHTML.from_document()

    assert LazyHTML.query(doc, "#user-display-name") |> LazyHTML.text() =~ "Alex"
    assert LazyHTML.query(doc, "#workspace-name") |> LazyHTML.text() =~ "Alex"
    assert Enum.empty?(LazyHTML.query(doc, "#workspace-switcher"))
  end

  test "a switched-to workspace renders in its own currency", %{conn: conn} do
    member = oidc_user("member", "Member")
    owner = oidc_user("owner", "Owner")
    owner_workspace = Accounts.current_workspace_for_user(owner)
    {:ok, _} = Accounts.share_workspace_with_email(owner_workspace, "member@example.com", owner)

    {:ok, _} =
      Settings.update_settings(Settings.get_settings!(owner_workspace), %{"currency" => "GBP"})

    add_debt(owner_workspace)

    html =
      conn
      |> Plug.Test.init_test_session(user_id: member.id, workspace_id: owner_workspace.id)
      |> get("/")
      |> html_response(200)

    assert html =~ "£"
    refute html =~ "$100.00"
  end

  test "renaming the workspace is reflected in the next invitation email" do
    owner = oidc_user("owner", "Owner")
    # Drain the welcome email sent on first login.
    assert_email_sent(subject: "Welcome to Debt Relief Tracker!")
    workspace = Accounts.current_workspace_for_user(owner)

    assert {:ok, nil} =
             AccountOps.save_settings(owner, workspace, %{"workspace_name" => "Our Debts"})

    workspace = Accounts.current_workspace_for_user(owner)
    assert {:ok, _} = AccountOps.share_workspace(owner, workspace, "new@example.com")
    assert_email_sent(subject: "You've been invited to Our Debts")
  end

  test "an Auth0 database user renames themselves via Auth0" do
    enable_auth0_management()
    Req.Test.set_req_test_to_shared()

    Req.Test.stub(DebtReliefTrackerWeb.Auth0Management, fn
      %{request_path: "/oauth/token"} = conn -> Req.Test.json(conn, %{"access_token" => "t"})
      conn -> Req.Test.json(conn, %{})
    end)

    user = oidc_user("auth0|a", "a@example.com")
    workspace = Accounts.current_workspace_for_user(user)

    assert AccountOps.settings_modal(user, workspace).display_name_editability != :read_only

    assert {:ok, _} = AccountOps.save_settings(user, workspace, %{"display_name" => "Alex Smith"})
    assert Accounts.get_user!(user.id).display_name == "Alex Smith"
  end

  test "an Auth0 social user's name is read-only and a crafted rename is ignored" do
    enable_auth0_management()
    user = oidc_user("google-oauth2|1", "Gabe")
    workspace = Accounts.current_workspace_for_user(user)

    assert AccountOps.settings_modal(user, workspace).display_name_editability == :read_only
    assert {:ok, _} = AccountOps.save_settings(user, workspace, %{"display_name" => "Hacked"})
    assert Accounts.get_user!(user.id).display_name == "Gabe"
  end

  test "a saved theme is applied on the next page load", %{conn: conn} do
    user = oidc_user("themer", "Themer")
    assert :ok = AccountOps.save_theme(user, "dark")
    assert Accounts.get_user!(user.id).preferences.theme == :dark

    workspace = Accounts.current_workspace_for_user(user)
    add_debt(workspace)

    doc =
      conn
      |> Plug.Test.init_test_session(user_id: user.id)
      |> get("/")
      |> html_response(200)
      |> LazyHTML.from_document()

    assert LazyHTML.attribute(LazyHTML.query(doc, "[data-saved-theme]"), "data-saved-theme") ==
             ["dark"]
  end
end
