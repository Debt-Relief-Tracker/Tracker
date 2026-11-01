defmodule DebtReliefTrackerWeb.Holo.AccountOpsTest do
  # Not async: flips global OIDC config and the Swoosh shared test process.
  use DebtReliefTracker.DataCase

  alias DebtReliefTracker.{Accounts, Settings}
  alias DebtReliefTrackerWeb.Holo.AccountOps

  defp enable_oidc do
    Application.put_env(:debt_relief_tracker, :oidc,
      issuer: "https://idp.example.com",
      client_id: "test-client",
      client_secret: "test-secret"
    )

    Application.put_env(:swoosh, :shared_test_process, self())

    on_exit(fn ->
      Application.put_env(:debt_relief_tracker, :oidc, nil)
      Application.delete_env(:swoosh, :shared_test_process)
    end)
  end

  defp oidc_user(sub, name) do
    Accounts.get_or_create_user_from_oidc!(%{
      "sub" => sub,
      "email" => "#{sub}@example.com",
      "name" => name
    })
  end

  describe "no-auth mode" do
    setup do
      %{workspace: Accounts.ensure_default_workspace!()}
    end

    test "one Save writes name, tracker name, and currency together", %{workspace: workspace} do
      assert {:ok, snapshot} =
               AccountOps.save_settings(nil, workspace, %{
                 "display_name" => "Sam",
                 "workspace_name" => "Sam's Plan",
                 "currency" => "GBP"
               })

      assert snapshot.settings.currency == "GBP"
      assert Accounts.get_default_user!().display_name == "Sam"
      assert Accounts.get_workspace!(workspace.id).name == "Sam's Plan"
      assert Settings.get_settings!(workspace).currency == "GBP"
    end

    test "an unchanged currency doesn't touch settings", %{workspace: workspace} do
      assert {:ok, nil} =
               AccountOps.save_settings(nil, workspace, %{
                 "display_name" => "Sam",
                 "workspace_name" => "Plan",
                 "currency" => Settings.get_settings!(workspace).currency
               })
    end

    test "an invalid field blocks the whole save", %{workspace: workspace} do
      before_name = Accounts.get_default_user!().display_name

      assert {:error, %{workspace_name: _}} =
               AccountOps.save_settings(nil, workspace, %{
                 "display_name" => "Sam",
                 "workspace_name" => "",
                 "currency" => "GBP"
               })

      assert Accounts.get_default_user!().display_name == before_name
      assert Settings.get_settings!(workspace).currency == "USD"
    end

    test "a blank display name is rejected", %{workspace: workspace} do
      assert {:error, %{display_name: _}} =
               AccountOps.save_settings(nil, workspace, %{
                 "display_name" => "  ",
                 "workspace_name" => workspace.name,
                 "currency" => "USD"
               })
    end

    test "an unknown currency is ignored rather than written", %{workspace: workspace} do
      assert {:ok, nil} =
               AccountOps.save_settings(nil, workspace, %{
                 "display_name" => "Sam",
                 "workspace_name" => workspace.name,
                 "currency" => "XXX"
               })

      assert Settings.get_settings!(workspace).currency == "USD"
    end

    test "settings modal: implicit user owns the tracker and sees no sharing data", %{
      workspace: workspace
    } do
      modal = AccountOps.settings_modal(nil, workspace)

      assert modal.type == :settings
      assert modal.is_owner
      assert modal.display_name_editability == :local
      assert modal.pending_invitations == []
    end

    test "restart_tutorial resets tutorial_seen" do
      user = Accounts.get_default_user!()
      {:ok, _} = Accounts.set_tutorial_seen(user, true)

      :ok = AccountOps.restart_tutorial(nil)

      refute Accounts.get_default_user!().tutorial_seen
    end

    test "the theme saves to the implicit default user" do
      :ok = AccountOps.save_theme(nil, "light")
      assert Accounts.get_default_user!().preferences.theme == :light
    end

    test "an unknown theme is not saved" do
      assert AccountOps.save_theme(nil, "neon") == :error
      assert Accounts.get_default_user!().preferences.theme == :system
    end
  end

  describe "OIDC mode" do
    setup do
      enable_oidc()
      owner = oidc_user("owner", "Owner")
      %{owner: owner, workspace: Accounts.current_workspace_for_user(owner)}
    end

    test "inviting an unknown email creates a pending invitation that can be canceled", %{
      owner: owner,
      workspace: workspace
    } do
      assert {:ok, "Invited new@example.com" <> _} =
               AccountOps.share_workspace(owner, workspace, "new@example.com")

      assert [%{email: "new@example.com", id: id}] =
               AccountOps.settings_modal(owner, workspace).pending_invitations

      assert {:error, "new@example.com has already been invited."} =
               AccountOps.share_workspace(owner, workspace, "new@example.com")

      :ok = AccountOps.cancel_invitation(owner, workspace, id)
      assert AccountOps.settings_modal(owner, workspace).pending_invitations == []
    end

    test "sharing with an existing user adds a member who can be removed", %{
      owner: owner,
      workspace: workspace
    } do
      member = oidc_user("member", "Member")

      assert {:ok, "Shared with member@example.com."} =
               AccountOps.share_workspace(owner, workspace, "member@example.com")

      assert {:error, "member@example.com already has access."} =
               AccountOps.share_workspace(owner, workspace, "member@example.com")

      assert [%{id: member_row_id, name: "Member"}] =
               AccountOps.settings_modal(owner, workspace).accepted_members

      assert AccountOps.actor_names(workspace)[member.id] == "Member"

      :ok = AccountOps.remove_member(owner, workspace, member_row_id)
      assert AccountOps.settings_modal(owner, workspace).accepted_members == []
    end

    test "a blank email is rejected", %{owner: owner, workspace: workspace} do
      assert {:error, _} = AccountOps.share_workspace(owner, workspace, "   ")
    end

    test "non-owners can't share, cancel or remove, and see read-only settings", %{
      owner: owner,
      workspace: workspace
    } do
      member = oidc_user("member", "Member")
      {:ok, _} = Accounts.share_workspace_with_email(workspace, "member@example.com", owner)
      {:ok, _} = Accounts.share_workspace_with_email(workspace, "pending@example.com", owner)
      [%{id: invitation_id}] = Accounts.list_pending_invitations(workspace)
      [%{id: member_row_id}] = Accounts.list_workspace_members(workspace)

      assert {:error, _} = AccountOps.share_workspace(member, workspace, "x@example.com")
      :ok = AccountOps.cancel_invitation(member, workspace, invitation_id)
      :ok = AccountOps.remove_member(member, workspace, member_row_id)
      assert length(Accounts.list_pending_invitations(workspace)) == 1
      assert length(Accounts.list_workspace_members(workspace)) == 1

      modal = AccountOps.settings_modal(member, workspace)
      refute modal.is_owner
      assert modal.accepted_members == []
      assert modal.pending_invitations == []

      # Tracker name and currency are owner-only; a crafted save skips them.
      assert {:ok, nil} =
               AccountOps.save_settings(member, workspace, %{
                 "display_name" => "Member 2",
                 "workspace_name" => "Hijacked",
                 "currency" => "JPY"
               })

      assert Accounts.get_workspace!(workspace.id).name == workspace.name
      assert Settings.get_settings!(workspace).currency == "USD"
      assert Accounts.get_user!(member.id).display_name == "Member 2"
    end

    test "switchable_workspace_id only allows workspaces the user belongs to", %{
      owner: owner,
      workspace: workspace
    } do
      other = oidc_user("other", "Other")
      other_workspace = Accounts.current_workspace_for_user(other)

      assert AccountOps.switchable_workspace_id(owner, workspace.id) == workspace.id
      assert AccountOps.switchable_workspace_id(owner, other_workspace.id) == nil
      assert AccountOps.switchable_workspace_id(owner, "nope") == nil
      assert AccountOps.switchable_workspace_id(nil, workspace.id) == nil
    end
  end
end
