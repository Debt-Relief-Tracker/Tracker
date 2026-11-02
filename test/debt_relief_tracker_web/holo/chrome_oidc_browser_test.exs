defmodule DebtReliefTrackerWeb.Holo.ChromeOidcBrowserTest do
  # Real-browser tests of the dashboard chrome with OIDC "enabled" (see
  # live/dashboard_live_oidc_test.exs): the browser gets a genuine signed
  # Phoenix session cookie for a seeded user (BrowserCase.sign_in/2); only
  # the IdP round trip itself is faked/absent.
  use DebtReliefTracker.BrowserCase

  alias DebtReliefTracker.{Accounts, Debts, Settings}
  alias DebtReliefTrackerWeb.Holo.DashboardPage

  @session_cookie "_debt_relief_tracker_key"

  setup do
    # An unroutable port: logout redirects to <issuer>/v2/logout, which just
    # fails to connect instead of leaving the test machine.
    Application.put_env(:debt_relief_tracker, :oidc,
      issuer: "http://127.0.0.1:1",
      client_id: "test-client",
      client_secret: "test-secret"
    )

    Application.put_env(:swoosh, :shared_test_process, self())

    on_exit(fn ->
      Application.put_env(:debt_relief_tracker, :oidc, nil)
      Application.delete_env(:swoosh, :shared_test_process)
    end)

    owner = user("owner", "Owner")
    {:ok, _} = Accounts.set_tutorial_seen(owner, true)
    {:ok, owner: owner}
  end

  defp user(sub, name) do
    Accounts.get_or_create_user_from_oidc!(%{
      "sub" => sub,
      "email" => "#{sub}@example.com",
      "name" => name
    })
  end

  defp open_settings(ctx) do
    ctx |> click("#settings-button") |> assert_selector("#settings-modal")
  end

  test "without a session / redirects to login (conn level: the IdP is not reachable)" do
    conn =
      Phoenix.ConnTest.dispatch(
        Phoenix.ConnTest.build_conn(),
        DebtReliefTrackerWeb.Endpoint,
        :get,
        "/"
      )

    assert Phoenix.ConnTest.redirected_to(conn) == "/auth/login"
  end

  test "signed-in user sees their name and workspace; logout POST validates CSRF and drops the session",
       %{owner: owner} = ctx do
    ctx
    |> sign_in(owner)
    |> visit_page(DashboardPage)
    |> assert_text("#user-display-name", "Owner")
    |> assert_text("#workspace-name", "Owner's Debts")
    |> click("#logout-button")

    # The POST /auth/logout validated its CSRF token (otherwise Phoenix would
    # 403 and keep the session) and replied with a session-dropping cookie.
    wait_until(fn ->
      not Enum.any?(cookies(ctx), &(&1["name"] == @session_cookie and &1["value"] != ""))
    end)
  end

  test "sharing: invite by email, then cancel the invitation; members can be removed",
       %{owner: owner} = ctx do
    ctx
    |> sign_in(owner)
    |> visit_page(DashboardPage)
    |> open_settings()
    |> fill("#settings-share-email", "friend@example.com")
    |> click("#settings-share-submit")
    |> assert_text("#settings-notice", "Invited friend@example.com")
    |> assert_text("#settings-people-list", "friend@example.com")

    [invitation] = Accounts.list_pending_invitations(Accounts.current_workspace_for_user(owner))

    ctx
    |> click("#cancel-invitation-#{invitation.id}")
    |> refute_selector("#invitation-#{invitation.id}")

    assert Accounts.list_pending_invitations(Accounts.current_workspace_for_user(owner)) == []

    # Share with an existing user, then remove them.
    member = user("pal", "Pal")
    ws = Accounts.current_workspace_for_user(owner)

    ctx
    |> fill("#settings-share-email", member.email)
    |> click("#settings-share-submit")
    |> assert_text("#settings-notice", "Shared with")
    |> assert_text("#settings-people-list", "Pal")

    [m] = Accounts.list_workspace_members(ws)

    ctx
    |> click("#remove-member-#{m.id}")
    |> refute_selector("#member-#{m.id}")

    assert Accounts.list_workspace_members(ws) == []
  end

  test "workspace switcher switches and the choice sticks across a reload",
       %{owner: owner} = ctx do
    other = user("zed", "Zed")
    other_ws = Accounts.current_workspace_for_user(other)
    {:ok, _} = Accounts.share_workspace_with_email(other_ws, owner.email, other)

    {:ok, _} =
      Settings.update_settings(Settings.get_settings!(other_ws), %{"currency" => "GBP"})

    {:ok, _} =
      Debts.create_debt(other_ws, other, %{
        "name" => "Other Visa",
        "type" => "revolving",
        "balance" => "100.00",
        "apr" => "10",
        "minimum_payment_floor" => "35.00",
        "minimum_payment_rate" => "0.02"
      })

    ctx
    |> sign_in(owner)
    |> visit_page(DashboardPage)
    |> assert_text("#workspace-name", "Owner's Debts")
    |> select("#workspace-switcher", other_ws.id)
    |> assert_text("#workspace-name", "Zed's Debts")
    |> assert_text("#holo-dashboard", "Other Visa")
    |> assert_text("#holo-dashboard", "£100.00")

    # Zed's workspace sorts after Owner's, so the default was Owner's.
    # Not the owner of this one: no sharing section, no editable tracker name.
    ctx |> open_settings() |> refute_selector("#settings-people")
    refute_selector(ctx, "#settings-workspace-name")
    click(ctx, "#settings-cancel")

    ctx
    |> visit_page(DashboardPage)
    |> assert_text("#workspace-name", "Zed's Debts")
  end

  defp wait_until(fun, tries \\ 50) do
    cond do
      fun.() -> :ok
      tries == 0 -> flunk("condition not met in time")
      true -> Process.sleep(100) && wait_until(fun, tries - 1)
    end
  end
end
