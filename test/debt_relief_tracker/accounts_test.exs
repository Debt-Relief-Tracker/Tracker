defmodule DebtReliefTracker.AccountsTest do
  use DebtReliefTracker.DataCase

  import Swoosh.TestAssertions

  alias DebtReliefTracker.Accounts
  alias DebtReliefTracker.Accounts.Scope
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

      assert Accounts.cancel_invitation(workspace, -1) == {:error, :not_found}
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

      assert Accounts.remove_member(workspace, -1) == {:error, :not_found}
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
end
