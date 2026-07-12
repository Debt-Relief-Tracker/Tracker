defmodule DebtReliefTracker.AccountsTest do
  use DebtReliefTracker.DataCase

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

  describe "share_workspace_with_email/2" do
    test "grants member access to a known user" do
      owner = Accounts.get_or_create_user_from_oidc!(%{"sub" => "a", "email" => "a@example.com"})
      member = Accounts.get_or_create_user_from_oidc!(%{"sub" => "b", "email" => "b@example.com"})
      workspace = Accounts.current_workspace_for_user(owner)

      assert {:ok, _member} = Accounts.share_workspace_with_email(workspace, "b@example.com")

      assert workspace in Accounts.list_workspaces_for_user(member)
      refute Accounts.owner?(workspace, member)
    end

    test "returns an error when no user with that email has ever logged in" do
      owner = Accounts.get_or_create_user_from_oidc!(%{"sub" => "a", "email" => "a@example.com"})
      workspace = Accounts.current_workspace_for_user(owner)

      assert Accounts.share_workspace_with_email(workspace, "nobody@example.com") ==
               {:error, :user_not_found}
    end
  end

  describe "current_workspace_for_user/2" do
    test "prefers the given id when the user belongs to it, else falls back to the first" do
      owner = Accounts.get_or_create_user_from_oidc!(%{"sub" => "a", "email" => "a@example.com"})
      member = Accounts.get_or_create_user_from_oidc!(%{"sub" => "b", "email" => "b@example.com"})
      owner_workspace = Accounts.current_workspace_for_user(owner)

      {:ok, _} = Accounts.share_workspace_with_email(owner_workspace, "b@example.com")
      member_own_workspace = Accounts.current_workspace_for_user(member)

      assert Accounts.current_workspace_for_user(member, owner_workspace.id).id ==
               owner_workspace.id

      assert Accounts.current_workspace_for_user(member, -1).id == member_own_workspace.id
    end
  end
end
