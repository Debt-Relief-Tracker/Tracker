defmodule DebtReliefTrackerWeb.AdminLiveTest do
  use DebtReliefTrackerWeb.ConnCase

  import Phoenix.LiveViewTest
  import Swoosh.TestAssertions

  alias DebtReliefTracker.{Accounts, Support}

  describe "no-auth mode (OIDC disabled)" do
    test "/admin is reachable and shows the settings tab by default", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin")

      assert has_element?(view, "#admin-settings-form")
    end

    test "clicking the Emails tab switches content without a page reload", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin")

      html = view |> element(~s(a[href="/admin?tab=emails"])) |> render_click()

      assert html =~ "sent-emails"
      refute has_element?(view, "#admin-settings-form")
    end

    test "the dashboard footer links to /admin even with no admin user (no-auth mode is fully trusted)",
         %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/")

      assert html =~ ~s(href="/admin")
    end

    test "the admin page footer also has the Donate link", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin")

      assert has_element?(view, "#app-footer #donate-link")
      assert has_element?(view, "#donate-modal")
    end
  end

  describe "email provider warning" do
    test "hidden when a real adapter (e.g. the test env's) is configured", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin?tab=emails")

      refute has_element?(view, "#mailer-not-configured-warning")
    end

    test "shown on the emails tab when the mailer is on the Local (unconfigured) adapter", %{
      conn: conn
    } do
      previous = Application.get_env(:debt_relief_tracker, DebtReliefTracker.Mailer)

      Application.put_env(:debt_relief_tracker, DebtReliefTracker.Mailer,
        adapter: Swoosh.Adapters.Local
      )

      on_exit(fn ->
        Application.put_env(:debt_relief_tracker, DebtReliefTracker.Mailer, previous)
      end)

      {:ok, view, _html} = live(conn, ~p"/admin?tab=emails")

      assert has_element?(
               view,
               "#mailer-not-configured-warning",
               "No email provider is configured"
             )
    end
  end

  describe "OIDC enabled" do
    setup do
      Application.put_env(:debt_relief_tracker, :oidc,
        issuer: "https://idp.example.com",
        client_id: "test-client",
        client_secret: "test-secret",
        roles_claim: "https://example.com/roles"
      )

      Application.put_env(:swoosh, :shared_test_process, self())

      on_exit(fn ->
        Application.put_env(:debt_relief_tracker, :oidc, nil)
        Application.delete_env(:swoosh, :shared_test_process)
      end)

      :ok
    end

    test "redirects to /auth/login when there's no session user", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/auth/login"}}} = live(conn, ~p"/admin")
    end

    test "redirects a non-admin logged-in user back to \"/\"", %{conn: conn} do
      user =
        Accounts.get_or_create_user_from_oidc!(%{"sub" => "regular", "email" => "r@example.com"})

      conn = Plug.Test.init_test_session(conn, user_id: user.id)

      assert {:error, {:redirect, %{to: "/", flash: %{"error" => _}}}} = live(conn, ~p"/admin")
    end

    test "the dashboard footer hides the admin link for a non-admin, shows it for an admin", %{
      conn: conn
    } do
      user =
        Accounts.get_or_create_user_from_oidc!(%{"sub" => "regular", "email" => "r@example.com"})

      conn = Plug.Test.init_test_session(conn, user_id: user.id)
      {:ok, _view, html} = live(conn, ~p"/")
      refute html =~ ~s(href="/admin")

      admin =
        Accounts.get_or_create_user_from_oidc!(%{
          "sub" => "admin",
          "email" => "admin@example.com",
          "https://example.com/roles" => ["admin"]
        })

      conn = Plug.Test.init_test_session(conn, user_id: admin.id)
      {:ok, _view, html} = live(conn, ~p"/")
      assert html =~ ~s(href="/admin")
    end

    test "an admin can view both tabs, save settings, and resend a sent email", %{conn: conn} do
      admin =
        Accounts.get_or_create_user_from_oidc!(%{
          "sub" => "admin",
          "email" => "admin@example.com",
          "name" => "Admin",
          "https://example.com/roles" => ["admin"]
        })

      assert [sent_email] = Accounts.list_sent_emails()
      assert sent_email.template == :welcome

      conn = Plug.Test.init_test_session(conn, user_id: admin.id)
      {:ok, view, _html} = live(conn, ~p"/admin")

      assert has_element?(view, "#admin-settings-form")

      view
      |> form("#admin-settings-form", %{
        "site_setting" => %{"site_name" => "Our Tracker", "from_email" => "hello@example.com"}
      })
      |> render_submit()

      assert has_element?(view, "*", "Settings saved.")

      {:ok, view, html} = live(conn, ~p"/admin?tab=emails")
      assert html =~ "welcome"

      view
      |> element("button[phx-click=resend]")
      |> render_click()

      assert_email_sent(subject: "Welcome to Debt Relief Tracker!")
    end
  end

  describe "support emails tab" do
    test "lists logged support emails and shows detail in a modal", %{conn: conn} do
      {:ok, _support_email} =
        Support.log_support_email(%{
          "from" => "user@example.com",
          "to" => "support@debtreliefapp.com",
          "subject" => "Need help",
          "body" => "The full body text",
          "received_at" => ~U[2026-09-01 12:00:00.000000Z]
        })

      {:ok, view, _html} = live(conn, ~p"/admin?tab=support_emails")

      assert has_element?(view, "#support-emails", "Need help")

      html =
        view
        |> element(~s(button[phx-click="view_support_email"]))
        |> render_click()

      assert html =~ "The full body text"
    end
  end

  describe "API tokens tab" do
    test "creating a token shows the raw value once, then lists it as active", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin?tab=tokens")

      view |> element(~s(button[phx-click="new_token"])) |> render_click()

      html =
        view
        |> form("#new-token-form", %{
          "api_token" => %{"name" => "Postmark webhook", "scopes" => ["support_emails:write"]}
        })
        |> render_submit()

      assert html =~ "won&#39;t be shown again."
      assert [%{name: "Postmark webhook"}] = Accounts.list_api_tokens()

      view |> element(~s(button[phx-click="dismiss_new_token"])) |> render_click()

      assert has_element?(view, "#api-tokens", "Postmark webhook")
      assert has_element?(view, "#api-tokens", "Active")
    end

    test "rejects a token with no scopes selected", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin?tab=tokens")

      view |> element(~s(button[phx-click="new_token"])) |> render_click()

      html =
        view
        |> form("#new-token-form", %{"api_token" => %{"name" => "Bad", "scopes" => [""]}})
        |> render_submit()

      assert html =~ "can&#39;t be blank"
      assert Accounts.list_api_tokens() == []
    end

    test "revoking a token marks it inactive", %{conn: conn} do
      {:ok, _raw_token, api_token} =
        Accounts.create_api_token(%{"name" => "T", "scopes" => ["support_emails:write"]}, nil)

      {:ok, view, _html} = live(conn, ~p"/admin?tab=tokens")

      view
      |> element(~s(button[phx-click="revoke_token"][phx-value-id="#{api_token.id}"]))
      |> render_click()

      assert has_element?(view, "#api-tokens", "Revoked")

      refute has_element?(
               view,
               ~s(button[phx-click="revoke_token"][phx-value-id="#{api_token.id}"])
             )
    end
  end

  describe "users tab" do
    test "lists users and opens the detail modal", %{conn: conn} do
      user =
        Accounts.get_or_create_user_from_oidc!(%{
          "sub" => "google-oauth2|1",
          "email" => "sam@example.com",
          "name" => "Sam"
        })

      {:ok, view, _html} = live(conn, ~p"/admin?tab=users")

      assert has_element?(view, "#users", "sam@example.com")
      assert has_element?(view, "#users", "Google")
      refute has_element?(view, "#user-detail-modal")

      view |> element("#view-user-#{user.id}") |> render_click()

      assert has_element?(view, "#user-detail-modal", "Sam")
      assert has_element?(view, "#user-detail-workspaces", "Sam's Debts")
    end

    test "per-page select and next link paginate via the URL", %{conn: conn} do
      # 11 + the implicit default user (touched on every no-auth mount) = 12.
      Accounts.get_default_user!()
      for i <- 1..11, do: Accounts.get_or_create_user_from_oidc!(%{"sub" => "u#{i}"})

      {:ok, view, _html} = live(conn, ~p"/admin?tab=users")
      assert has_element?(view, "#users-pager", "Page 1 of 1")

      view |> form("#users-per-page-form", %{"per_page" => "10"}) |> render_change()
      assert_patch(view, ~p"/admin?tab=users&page=1&per_page=10")
      assert has_element?(view, "#users-pager", "Page 1 of 2")

      view |> element("#users-next") |> render_click()
      assert_patch(view, ~p"/admin?tab=users&page=2&per_page=10")
      assert has_element?(view, "#users-pager", "Showing 11–12 of 12")
    end

    test "no-auth mode tracks last seen on the implicit default user", %{conn: conn} do
      assert Accounts.get_default_user!().last_seen_at == nil

      {:ok, view, _html} = live(conn, ~p"/admin?tab=users")

      default_user = Accounts.get_default_user!()
      assert %DateTime{} = default_user.last_seen_at
      assert has_element?(view, "#users", "N/A (no-auth)")
    end

    test "an unsupported per_page falls back to the default", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin?tab=users&per_page=999")

      assert has_element?(view, "#users-per-page option[selected][value='25']")
    end
  end

  describe "last seen tracking (OIDC enabled)" do
    setup do
      Application.put_env(:debt_relief_tracker, :oidc,
        issuer: "https://idp.example.com",
        client_id: "test-client",
        client_secret: "test-secret"
      )

      on_exit(fn -> Application.put_env(:debt_relief_tracker, :oidc, nil) end)
      :ok
    end

    test "a connected mount bumps the user's last_seen_at", %{conn: conn} do
      user = Accounts.get_or_create_user_from_oidc!(%{"sub" => "seen", "name" => "Seen"})
      assert user.last_seen_at == nil

      conn = Plug.Test.init_test_session(conn, user_id: user.id)
      {:ok, _view, _html} = live(conn, ~p"/")

      assert %DateTime{} = Accounts.get_user!(user.id).last_seen_at
    end
  end
end
