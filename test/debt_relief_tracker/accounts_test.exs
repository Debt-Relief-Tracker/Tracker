defmodule DebtReliefTracker.AccountsTest do
  use DebtReliefTracker.DataCase

  import Swoosh.TestAssertions

  alias DebtReliefTracker.Accounts

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

      assert {:ok, _member} =
               Accounts.share_workspace_with_email(workspace, "b@example.com", owner)

      assert workspace in Accounts.list_workspaces_for_user(member)
      refute Accounts.owner?(workspace, member)
      assert_email_sent(to: {member.display_name, "b@example.com"})
    end

    test "creates a pending invitation and emails the address when no user with that email has ever logged in" do
      owner = Accounts.get_or_create_user_from_oidc!(%{"sub" => "a", "email" => "a@example.com"})
      workspace = Accounts.current_workspace_for_user(owner)

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
