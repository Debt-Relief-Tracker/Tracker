defmodule DebtReliefTracker.AccountsTest do
  use DebtReliefTracker.DataCase

  import Swoosh.TestAssertions

  alias DebtReliefTracker.Accounts
  alias DebtReliefTracker.Accounts.{ApiToken, Scope}
  alias DebtReliefTracker.Settings

  describe "ensure_default_workspace!/0" do
    test "creates the implicit user, workspace, and owner membership on first call" do
      workspace = Accounts.ensure_default_workspace!()

      assert workspace.name == "My Debts"
      assert %DebtReliefTracker.Accounts.Workspace{} = workspace
    end

    test "is idempotent -- repeated calls return the same workspace" do
      workspace1 = Accounts.ensure_default_workspace!()
      workspace2 = Accounts.ensure_default_workspace!()

      assert workspace1.id == workspace2.id
    end
  end

  describe "get_or_create_user_from_oidc!/1" do
    test "creates a user with their own owned workspace on first login" do
      user =
        Accounts.get_or_create_user_from_oidc!(%{
          "sub" => "oidc|abc123",
          "email" => "alex@example.com",
          "name" => "Alex"
        })

      assert user.external_subject == "oidc|abc123"
      assert user.email == "alex@example.com"

      workspace = Accounts.current_workspace_for_user(user)
      assert workspace.name == "Alex's Debts"
      assert Accounts.owner?(workspace, user)
    end

    test "is idempotent on the same sub -- returns the same user, no duplicate workspace" do
      claims = %{"sub" => "oidc|abc123", "email" => "alex@example.com", "name" => "Alex"}

      user1 = Accounts.get_or_create_user_from_oidc!(claims)
      user2 = Accounts.get_or_create_user_from_oidc!(claims)

      assert user1.id == user2.id
      assert Accounts.list_workspaces_for_user(user1) |> length() == 1
    end

    test "re-syncs display_name from the name claim on a returning login" do
      claims = %{
        "sub" => "auth0|abc",
        "email" => "alex@example.com",
        "name" => "alex@example.com"
      }

      Accounts.get_or_create_user_from_oidc!(claims)

      user = Accounts.get_or_create_user_from_oidc!(%{claims | "name" => "Alex Smith"})

      assert user.display_name == "Alex Smith"
      # Only a default -- the workspace name isn't renamed alongside.
      assert Accounts.current_workspace_for_user(user).name == "alex@example.com's Debts"
    end

    test "keeps the current display_name when the name claim is missing" do
      claims = %{"sub" => "auth0|abc", "email" => "alex@example.com", "name" => "Alex"}
      Accounts.get_or_create_user_from_oidc!(claims)

      user = Accounts.get_or_create_user_from_oidc!(Map.delete(claims, "name"))

      assert user.display_name == "Alex"
    end

    test "doesn't overwrite a locally overridden display_name" do
      claims = %{"sub" => "oidc|abc", "email" => "alex@example.com", "name" => "Alex"}
      user = Accounts.get_or_create_user_from_oidc!(claims)
      {:ok, _} = Accounts.update_display_name(user, %{"display_name" => "Lexi"})

      user = Accounts.get_or_create_user_from_oidc!(%{claims | "name" => "Alexander"})

      assert user.display_name == "Lexi"
    end

    test "an unchanged returning login doesn't write the row" do
      claims = %{"sub" => "oidc|abc", "email" => "alex@example.com", "name" => "Alex"}
      user1 = Accounts.get_or_create_user_from_oidc!(claims)
      user2 = Accounts.get_or_create_user_from_oidc!(claims)

      assert user1.updated_at == user2.updated_at
    end
  end

  describe "display names" do
    setup do
      on_exit(fn -> Application.put_env(:debt_relief_tracker, :auth0_management, nil) end)
    end

    defp enable_auth0_management do
      Application.put_env(:debt_relief_tracker, :auth0_management,
        client_id: "m2m-id",
        client_secret: "m2m-secret",
        domain: "https://tenant.example.auth0.com/"
      )
    end

    defp oidc_user(sub) do
      Accounts.get_or_create_user_from_oidc!(%{
        "sub" => sub,
        "email" => "#{sub}@example.com",
        "name" => "Original"
      })
    end

    test "display_name_editability/1 covers every mode" do
      assert Accounts.display_name_editability(Accounts.get_default_user!()) == :local
      assert Accounts.display_name_editability(oidc_user("auth0|db")) == :local_override
      assert Accounts.display_name_editability(oidc_user("google-oauth2|1")) == :local_override

      enable_auth0_management()
      assert Accounts.display_name_editability(oidc_user("auth0|db")) == :idp
      assert Accounts.display_name_editability(oidc_user("google-oauth2|1")) == :read_only
    end

    test "no-auth mode updates locally without flagging an override" do
      {:ok, user} =
        Accounts.update_display_name(Accounts.get_default_user!(), %{"display_name" => " Sam "})

      assert user.display_name == "Sam"
      refute user.display_name_overridden
    end

    test "an unchanged name is a no-op -- no override flag, no IdP call" do
      enable_auth0_management()
      # No Req.Test stub: any Auth0 request would raise.
      db_user = oidc_user("auth0|db")

      assert {:ok, ^db_user} =
               Accounts.update_display_name(db_user, %{"display_name" => "Original"})

      Application.put_env(:debt_relief_tracker, :auth0_management, nil)
      user = oidc_user("oidc|x")
      {:ok, user} = Accounts.update_display_name(user, %{"display_name" => "Original"})
      refute user.display_name_overridden
    end

    test "rejects a blank name" do
      assert {:error, %Ecto.Changeset{}} =
               Accounts.update_display_name(oidc_user("oidc|x"), %{"display_name" => "  "})
    end

    test "without write-back, saves locally and flags the override" do
      {:ok, user} = Accounts.update_display_name(oidc_user("oidc|x"), %{"display_name" => "Sam"})

      assert user.display_name == "Sam"
      assert user.display_name_overridden
    end

    test "an Auth0 database user is written to Auth0 first, then locally" do
      enable_auth0_management()
      test_pid = self()

      Req.Test.stub(DebtReliefTrackerWeb.Auth0Management, fn conn ->
        case {conn.method, conn.request_path} do
          {"POST", "/oauth/token"} ->
            {:ok, body, conn} = Plug.Conn.read_body(conn)
            send(test_pid, {:token_request, Jason.decode!(body)})
            Req.Test.json(conn, %{"access_token" => "mgmt-token"})

          {"PATCH", "/api/v2/users/auth0%7Cdb"} ->
            {:ok, body, conn} = Plug.Conn.read_body(conn)
            send(test_pid, {:patch, Plug.Conn.get_req_header(conn, "authorization"), body})
            Req.Test.json(conn, %{"user_id" => "auth0|db"})
        end
      end)

      {:ok, user} =
        Accounts.update_display_name(oidc_user("auth0|db"), %{"display_name" => "Sam"})

      assert user.display_name == "Sam"
      refute user.display_name_overridden

      assert_received {:token_request,
                       %{
                         "grant_type" => "client_credentials",
                         "audience" => "https://tenant.example.auth0.com/api/v2/"
                       }}

      assert_received {:patch, ["Bearer mgmt-token"], body}
      assert Jason.decode!(body) == %{"name" => "Sam"}
    end

    @tag :capture_log
    test "leaves the local name untouched when Auth0 rejects the update" do
      enable_auth0_management()

      Req.Test.stub(DebtReliefTrackerWeb.Auth0Management, fn
        %{request_path: "/oauth/token"} = conn ->
          Req.Test.json(conn, %{"access_token" => "mgmt-token"})

        conn ->
          conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{"error" => "boom"})
      end)

      user = oidc_user("auth0|db")

      assert {:error, :idp_update_failed} =
               Accounts.update_display_name(user, %{"display_name" => "Sam"})

      assert Accounts.get_user!(user.id).display_name == "Original"
    end

    test "an Auth0 social user can't edit their name" do
      enable_auth0_management()
      user = oidc_user("google-oauth2|1")

      assert {:error, :read_only} = Accounts.update_display_name(user, %{"display_name" => "Sam"})
      assert Accounts.get_user!(user.id).display_name == "Original"
    end
  end

  describe "share_workspace_with_email/3" do
    test "grants member access to a known user and emails them" do
      owner = Accounts.get_or_create_user_from_oidc!(%{"sub" => "a", "email" => "a@example.com"})
      member = Accounts.get_or_create_user_from_oidc!(%{"sub" => "b", "email" => "b@example.com"})
      workspace = Accounts.current_workspace_for_user(owner)

      # Both logins above sent a welcome email first -- drain those before
      # asserting on the share notification that follows.
      assert_email_sent(subject: "Welcome to Debt Relief Tracker!")
      assert_email_sent(subject: "Welcome to Debt Relief Tracker!")

      assert {:ok, _member} =
               Accounts.share_workspace_with_email(workspace, "b@example.com", owner)

      assert workspace in Accounts.list_workspaces_for_user(member)
      refute Accounts.owner?(workspace, member)
      assert_email_sent(to: {member.display_name, "b@example.com"})
    end

    test "creates a pending invitation and emails the address when no user with that email has ever logged in" do
      owner = Accounts.get_or_create_user_from_oidc!(%{"sub" => "a", "email" => "a@example.com"})
      workspace = Accounts.current_workspace_for_user(owner)

      # That login sent a welcome email first -- drain it before asserting on
      # the invitation email that follows.
      assert_email_sent(subject: "Welcome to Debt Relief Tracker!")

      assert {:ok, invitation} =
               Accounts.share_workspace_with_email(workspace, "nobody@example.com", owner)

      assert invitation.email == "nobody@example.com"
      assert invitation.workspace_id == workspace.id
      assert_email_sent(to: "nobody@example.com")
    end

    test "returns an error when the same email has already been invited" do
      owner = Accounts.get_or_create_user_from_oidc!(%{"sub" => "a", "email" => "a@example.com"})
      workspace = Accounts.current_workspace_for_user(owner)

      assert {:ok, _invitation} =
               Accounts.share_workspace_with_email(workspace, "nobody@example.com", owner)

      assert {:error, changeset} =
               Accounts.share_workspace_with_email(workspace, "nobody@example.com", owner)

      assert %{workspace_id: ["has already been taken"]} = errors_on(changeset)
    end

    test "fulfills a pending invitation the first time that email logs in via OIDC" do
      owner = Accounts.get_or_create_user_from_oidc!(%{"sub" => "a", "email" => "a@example.com"})
      workspace = Accounts.current_workspace_for_user(owner)

      {:ok, _invitation} =
        Accounts.share_workspace_with_email(workspace, "new@example.com", owner)

      new_user =
        Accounts.get_or_create_user_from_oidc!(%{
          "sub" => "new",
          "email" => "new@example.com",
          "name" => "Newcomer"
        })

      assert workspace in Accounts.list_workspaces_for_user(new_user)
      refute Accounts.owner?(workspace, new_user)
      assert Accounts.list_pending_invitations(workspace) == []
    end
  end

  describe "list_pending_invitations/1 and cancel_invitation/2" do
    test "lists and cancels pending invitations scoped to the workspace" do
      owner = Accounts.get_or_create_user_from_oidc!(%{"sub" => "a", "email" => "a@example.com"})
      workspace = Accounts.current_workspace_for_user(owner)

      {:ok, invitation} =
        Accounts.share_workspace_with_email(workspace, "nobody@example.com", owner)

      assert [%{id: id}] = Accounts.list_pending_invitations(workspace)
      assert id == invitation.id

      assert {:ok, _} = Accounts.cancel_invitation(workspace, invitation.id)
      assert Accounts.list_pending_invitations(workspace) == []
    end

    test "cancel_invitation/2 returns {:error, :not_found} for a foreign or missing id" do
      owner = Accounts.get_or_create_user_from_oidc!(%{"sub" => "a", "email" => "a@example.com"})
      workspace = Accounts.current_workspace_for_user(owner)

      assert Accounts.cancel_invitation(workspace, Ecto.UUID.generate()) == {:error, :not_found}
    end
  end

  describe "update_workspace/2" do
    test "renames the workspace" do
      workspace = Accounts.ensure_default_workspace!()

      assert {:ok, renamed} = Accounts.update_workspace(workspace, %{"name" => "Our Debts"})
      assert renamed.name == "Our Debts"
      assert Accounts.get_workspace!(workspace.id).name == "Our Debts"
    end

    test "returns an error changeset for a blank name" do
      workspace = Accounts.ensure_default_workspace!()

      assert {:error, changeset} = Accounts.update_workspace(workspace, %{"name" => ""})
      assert %{name: ["can't be blank"]} = errors_on(changeset)
    end
  end

  describe "list_confirmed_members/1" do
    test "includes the owner, owner first" do
      owner = Accounts.get_or_create_user_from_oidc!(%{"sub" => "a", "email" => "a@example.com"})
      member = Accounts.get_or_create_user_from_oidc!(%{"sub" => "b", "email" => "b@example.com"})
      workspace = Accounts.current_workspace_for_user(owner)

      {:ok, _} = Accounts.share_workspace_with_email(workspace, "b@example.com", owner)

      assert [first, second] = Accounts.list_confirmed_members(workspace)
      assert first.role == :owner
      assert first.user.id == owner.id
      assert second.user.id == member.id
    end

    test "excludes a pending invitation with no user yet" do
      owner = Accounts.get_or_create_user_from_oidc!(%{"sub" => "a", "email" => "a@example.com"})
      workspace = Accounts.current_workspace_for_user(owner)

      {:ok, _invitation} =
        Accounts.share_workspace_with_email(workspace, "nobody@example.com", owner)

      assert [%{role: :owner}] = Accounts.list_confirmed_members(workspace)
    end
  end

  describe "list_workspace_members/1 and remove_member/2" do
    test "lists accepted members excluding the owner's own row" do
      owner = Accounts.get_or_create_user_from_oidc!(%{"sub" => "a", "email" => "a@example.com"})
      member = Accounts.get_or_create_user_from_oidc!(%{"sub" => "b", "email" => "b@example.com"})
      workspace = Accounts.current_workspace_for_user(owner)

      {:ok, _} = Accounts.share_workspace_with_email(workspace, "b@example.com", owner)

      assert [%{user: %{id: user_id}}] = Accounts.list_workspace_members(workspace)
      assert user_id == member.id
    end

    test "remove_member/2 deletes a member's access" do
      owner = Accounts.get_or_create_user_from_oidc!(%{"sub" => "a", "email" => "a@example.com"})
      member = Accounts.get_or_create_user_from_oidc!(%{"sub" => "b", "email" => "b@example.com"})
      workspace = Accounts.current_workspace_for_user(owner)

      {:ok, _} = Accounts.share_workspace_with_email(workspace, "b@example.com", owner)
      assert [membership] = Accounts.list_workspace_members(workspace)

      assert {:ok, _} = Accounts.remove_member(workspace, membership.id)
      assert Accounts.list_workspace_members(workspace) == []
      refute workspace in Accounts.list_workspaces_for_user(member)
    end

    test "remove_member/2 returns {:error, :not_found} for a foreign or missing id" do
      owner = Accounts.get_or_create_user_from_oidc!(%{"sub" => "a", "email" => "a@example.com"})
      workspace = Accounts.current_workspace_for_user(owner)

      assert Accounts.remove_member(workspace, Ecto.UUID.generate()) == {:error, :not_found}
    end

    test "remove_member/2 downgrades the member's retirement profile back to manual instead of losing it" do
      owner = Accounts.get_or_create_user_from_oidc!(%{"sub" => "a", "email" => "a@example.com"})
      member = Accounts.get_or_create_user_from_oidc!(%{"sub" => "b", "email" => "b@example.com"})
      workspace = Accounts.current_workspace_for_user(owner)

      {:ok, _} = Accounts.share_workspace_with_email(workspace, "b@example.com", owner)

      {:ok, profile} =
        Settings.add_member_retirement_profile(workspace, member, %{
          "current_age" => "30",
          "retirement_age" => "65",
          "current_retirement_savings" => "0",
          "monthly_retirement_contribution" => "0",
          "monthly_gross_income" => "0",
          "post_debt_investment_pct" => "15.0",
          "expected_annual_return_pct" => "7.0"
        })

      assert [membership] = Accounts.list_workspace_members(workspace)
      assert {:ok, _} = Accounts.remove_member(workspace, membership.id)

      assert [reloaded] = Settings.list_retirement_profiles(workspace)
      assert reloaded.id == profile.id
      assert reloaded.user_id == nil
      assert reloaded.name == member.display_name
      assert reloaded.claim_email == member.email
    end

    test "remove_member/2 returns {:error, :cannot_remove_owner} for the owner's own row" do
      owner = Accounts.get_or_create_user_from_oidc!(%{"sub" => "a", "email" => "a@example.com"})
      workspace = Accounts.current_workspace_for_user(owner)

      owner_membership =
        DebtReliefTracker.Repo.get_by!(DebtReliefTracker.Accounts.WorkspaceMember,
          workspace_id: workspace.id,
          user_id: owner.id
        )

      assert Accounts.remove_member(workspace, owner_membership.id) ==
               {:error, :cannot_remove_owner}
    end
  end

  describe "get_or_create_user_from_oidc!/1 admin role sync" do
    setup do
      Application.put_env(:debt_relief_tracker, :oidc, roles_claim: "https://example.com/roles")
      on_exit(fn -> Application.put_env(:debt_relief_tracker, :oidc, nil) end)
      :ok
    end

    test "grants admin access when the configured role claim includes \"admin\"" do
      user =
        Accounts.get_or_create_user_from_oidc!(%{
          "sub" => "admin-user",
          "email" => "admin@example.com",
          "https://example.com/roles" => ["admin"]
        })

      assert user.is_admin
    end

    test "does not grant admin access without the role" do
      user =
        Accounts.get_or_create_user_from_oidc!(%{
          "sub" => "regular",
          "email" => "regular@example.com"
        })

      refute user.is_admin
    end

    test "re-syncs is_admin on a returning login, e.g. after a role is revoked" do
      claims = %{
        "sub" => "revoked",
        "email" => "revoked@example.com",
        "https://example.com/roles" => ["admin"]
      }

      user = Accounts.get_or_create_user_from_oidc!(claims)
      assert user.is_admin

      user =
        Accounts.get_or_create_user_from_oidc!(Map.delete(claims, "https://example.com/roles"))

      refute user.is_admin
    end
  end

  describe "admin?/1" do
    test "true only for a scope wrapping an admin user" do
      admin = %Accounts.User{is_admin: true}
      regular = %Accounts.User{is_admin: false}

      assert Accounts.admin?(Scope.for_user(admin))
      refute Accounts.admin?(Scope.for_user(regular))
      refute Accounts.admin?(Scope.for_user(nil))
    end
  end

  describe "get_or_create_user_from_oidc!/1 welcome email" do
    test "sends a welcome email to a brand-new user only" do
      claims = %{"sub" => "new", "email" => "new@example.com", "name" => "Newcomer"}

      Accounts.get_or_create_user_from_oidc!(claims)
      assert_email_sent(subject: "Welcome to Debt Relief Tracker!")

      Accounts.get_or_create_user_from_oidc!(claims)
      assert_no_email_sent()
    end

    test "sends no welcome email when disabled in site settings" do
      site_settings = Settings.get_site_settings()
      {:ok, _} = Settings.update_site_settings(site_settings, %{welcome_emails_enabled: false})

      Accounts.get_or_create_user_from_oidc!(%{"sub" => "x", "email" => "x@example.com"})

      assert_no_email_sent()
    end
  end

  describe "list_sent_emails/1 and resend_email/1" do
    test "records a sent welcome email, and resend/1 redelivers it" do
      user =
        Accounts.get_or_create_user_from_oidc!(%{
          "sub" => "resend-me",
          "email" => "resend@example.com",
          "name" => "Resend"
        })

      assert [sent_email] = Accounts.list_sent_emails()
      assert sent_email.template == :welcome
      assert sent_email.to == "resend@example.com"
      assert sent_email.status == :sent

      assert {:ok, :ok} = Accounts.resend_email(sent_email)
      assert_email_sent(to: {user.display_name, "resend@example.com"})
    end

    test "returns {:error, :gone} resending an invitation that's since been canceled" do
      owner = Accounts.get_or_create_user_from_oidc!(%{"sub" => "a", "email" => "a@example.com"})
      workspace = Accounts.current_workspace_for_user(owner)

      {:ok, invitation} =
        Accounts.share_workspace_with_email(workspace, "gone@example.com", owner)

      {:ok, _} = Accounts.cancel_invitation(workspace, invitation.id)

      sent_email = Enum.find(Accounts.list_sent_emails(), &(&1.template == :workspace_invitation))

      assert {:error, :gone} = Accounts.resend_email(sent_email)
    end
  end

  describe "current_workspace_for_user/2" do
    test "prefers the given id when the user belongs to it, else falls back to the first" do
      owner = Accounts.get_or_create_user_from_oidc!(%{"sub" => "a", "email" => "a@example.com"})
      member = Accounts.get_or_create_user_from_oidc!(%{"sub" => "b", "email" => "b@example.com"})
      owner_workspace = Accounts.current_workspace_for_user(owner)

      {:ok, _} = Accounts.share_workspace_with_email(owner_workspace, "b@example.com", owner)
      member_own_workspace = Accounts.current_workspace_for_user(member)

      assert Accounts.current_workspace_for_user(member, owner_workspace.id).id ==
               owner_workspace.id

      assert Accounts.current_workspace_for_user(member, -1).id == member_own_workspace.id
    end
  end

  describe "API tokens" do
    test "create_api_token/2 generates a raw token shown once, and hashes it for storage" do
      admin =
        Accounts.get_or_create_user_from_oidc!(%{"sub" => "admin", "email" => "a@example.com"})

      assert {:ok, raw_token, api_token} =
               Accounts.create_api_token(
                 %{"name" => "Webhook", "scopes" => ["support_emails:write"]},
                 admin
               )

      assert String.starts_with?(raw_token, "drt_")
      assert api_token.last_four == String.slice(raw_token, -4, 4)
      assert api_token.token_hash != raw_token
      assert api_token.created_by_user_id == admin.id
      refute ApiToken.revoked?(api_token)

      assert [listed] = Accounts.list_api_tokens()
      assert listed.id == api_token.id
    end

    test "create_api_token/2 with nil created_by (no-auth mode) leaves created_by_user_id nil" do
      assert {:ok, _raw_token, api_token} =
               Accounts.create_api_token(
                 %{"name" => "Local", "scopes" => ["support_emails:write"]},
                 nil
               )

      assert api_token.created_by_user_id == nil
    end

    test "create_api_token/2 rejects a blank name or unknown scope without generating a token" do
      assert {:error, changeset} =
               Accounts.create_api_token(
                 %{"name" => "", "scopes" => ["support_emails:write"]},
                 nil
               )

      assert "can't be blank" in errors_on(changeset).name

      assert {:error, changeset} =
               Accounts.create_api_token(
                 %{"name" => "Bad", "scopes" => ["not_a_real_scope"]},
                 nil
               )

      assert [_] = errors_on(changeset).scopes
    end

    test "authenticate_token/2 validates presence, scope, and revocation" do
      {:ok, raw_token, api_token} =
        Accounts.create_api_token(%{"name" => "T", "scopes" => ["support_emails:write"]}, nil)

      assert {:ok, authenticated} = Accounts.authenticate_token(raw_token, "support_emails:write")
      assert authenticated.id == api_token.id

      assert {:error, :invalid} =
               Accounts.authenticate_token("drt_not_a_real_token", "support_emails:write")

      assert {:error, :insufficient_scope} = Accounts.authenticate_token(raw_token, "other:scope")

      {:ok, _} = Accounts.revoke_api_token(api_token)
      assert {:error, :revoked} = Accounts.authenticate_token(raw_token, "support_emails:write")
    end

    test "authenticate_token/2 updates last_used_at on success" do
      {:ok, raw_token, api_token} =
        Accounts.create_api_token(%{"name" => "T", "scopes" => ["support_emails:write"]}, nil)

      assert api_token.last_used_at == nil

      {:ok, authenticated} = Accounts.authenticate_token(raw_token, "support_emails:write")
      assert authenticated.last_used_at != nil
    end
  end

  describe "user activity and list_users_for_admin/1" do
    defp oidc_user!(sub) do
      Accounts.get_or_create_user_from_oidc!(%{"sub" => sub, "name" => sub})
    end

    test "record_login!/1 stamps both last_login_at and last_seen_at" do
      user = oidc_user!("login")
      assert user.last_login_at == nil

      user = Accounts.record_login!(user)

      assert %DateTime{} = user.last_login_at
      assert user.last_seen_at == user.last_login_at
      assert Accounts.get_user!(user.id).last_login_at == user.last_login_at
    end

    test "touch_last_seen/1 writes when unset or stale, skips when fresh, ignores nil" do
      assert Accounts.touch_last_seen(nil) == nil

      user = oidc_user!("seen")
      touched = Accounts.touch_last_seen(user)
      assert %DateTime{} = touched.last_seen_at
      assert Accounts.get_user!(user.id).last_seen_at == touched.last_seen_at

      assert Accounts.touch_last_seen(touched) == touched

      stale = %{touched | last_seen_at: DateTime.add(DateTime.utc_now(), -10, :minute)}

      assert DateTime.compare(Accounts.touch_last_seen(stale).last_seen_at, stale.last_seen_at) ==
               :gt
    end

    test "orders most recently seen first, never-seen last, preloading memberships" do
      never = oidc_user!("never")
      older = oidc_user!("older") |> Accounts.touch_last_seen()

      newer = oidc_user!("newer") |> Accounts.record_login!()

      # Same-microsecond touches are possible in fast tests -- force a gap.
      older_at = DateTime.add(newer.last_seen_at, -1, :minute)

      from(u in DebtReliefTracker.Accounts.User, where: u.id == ^older.id)
      |> DebtReliefTracker.Repo.update_all(set: [last_seen_at: older_at])

      %{entries: entries} = Accounts.list_users_for_admin()

      assert Enum.map(entries, & &1.id) == [newer.id, older.id, never.id]

      assert [%{role: :owner, workspace: %{name: "newer's Debts"}}] =
               hd(entries).workspace_members
    end

    test "paginates and clamps out-of-range pages" do
      for i <- 1..12, do: oidc_user!("user#{i}")

      page2 = Accounts.list_users_for_admin(page: 2, per_page: 10)
      assert length(page2.entries) == 2
      assert %{page: 2, total: 12, total_pages: 2} = page2

      assert %{page: 2} = Accounts.list_users_for_admin(page: 99, per_page: 10)
      assert %{page: 1} = Accounts.list_users_for_admin(page: 0, per_page: 10)
    end
  end

  describe "update_preferences/2" do
    test "defaults to the system theme, and saves an explicit choice without touching other fields" do
      user = Accounts.get_default_user!()
      assert user.preferences.theme == :system

      assert {:ok, user} = Accounts.update_preferences(user, %{"theme" => "dark"})
      assert user.preferences.theme == :dark
      assert Accounts.get_user!(user.id).preferences.theme == :dark

      assert {:ok, user} = Accounts.update_preferences(user, %{theme: "system"})
      assert Accounts.get_user!(user.id).preferences.theme == :system
    end

    test "rejects an unknown theme" do
      user = Accounts.get_default_user!()

      assert {:error, _changeset} = Accounts.update_preferences(user, %{"theme" => "sepia"})
      assert Accounts.get_user!(user.id).preferences.theme == :system
    end
  end
end
