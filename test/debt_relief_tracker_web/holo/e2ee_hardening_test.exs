defmodule DebtReliefTrackerWeb.Holo.E2EEHardeningTest do
  # Not async: OIDC / E2EE config is global.
  use DebtReliefTrackerWeb.ConnCase

  import DebtReliefTracker.E2EEHelpers
  import DebtReliefTracker.MigrationHelpers

  alias DebtReliefTracker.{Accounts, Boot, Debts, E2EE, Repo}
  alias DebtReliefTracker.E2EE.{RateLimiter, Vault, Vaults}
  alias DebtReliefTrackerWeb.Holo.AccountOps
  alias DebtReliefTrackerWeb.Holo.Components.{HeaderBar, MigrationGate, SettingsModal, VaultGate}
  alias Hologram.Server

  setup do
    RateLimiter.reset()
    :ok
  end

  defp server_for(user), do: %Server{stash: %{holo_user_id: user.id}}

  describe "gates with E2EE off (items 1)" do
    test "every vault and migration command is rejected and writes nothing" do
      enable_oidc()
      {owner, ws} = owner_ws("off")
      refute E2EE.enabled?()
      s = server_for(owner)

      vault_cmds = [
        {:fetch_vault, %{}},
        {:create_vault, %{blob: "v1.AAAA.BBBB", wrap: passphrase_wrap()}},
        {:save_vault, %{base_rev: 1, blob: "x"}},
        {:add_key_wrap, %{wrap: passkey_wrap()}},
        {:remove_key_wrap, %{id: "x"}},
        {:rename_key_wrap, %{id: "x", label: "y"}},
        {:delete_vault, %{}},
        {:bogus, %{}}
      ]

      for {op, params} <- vault_cmds do
        assert %Server{next_action: %{name: :vault_result, params: %{ok: false, error: :invalid}}} =
                 VaultGate.command(op, params, s)
      end

      for op <- [:migration_status, :migration_export, :migration_dry_run] do
        assert %Server{next_action: %{params: %{ok: false, error: :invalid}}} =
                 MigrationGate.command(op, %{}, s)
      end

      assert %Server{next_action: %{params: %{ok: false, error: :invalid}}} =
               MigrationGate.command(:migration_finalize, %{digest: "d"}, s)

      refute Vaults.exists?(ws)
      assert Repo.aggregate(Vault, :count) == 0
    end
  end

  describe "vault owner-only (item 2)" do
    test "a workspace member cannot touch the vault; the owner can" do
      enable_oidc()
      enable_e2ee()
      {owner, ws} = owner_ws("own")
      member = oidc_user("mem")
      # Sharing is refused in E2EE mode, so grant membership directly.
      Repo.insert!(%DebtReliefTracker.Accounts.WorkspaceMember{
        workspace_id: ws.id,
        user_id: member.id,
        role: :member
      })

      owner_s = server_for(owner)
      mem_s = %{server_for(member) | session: %{"workspace_id" => ws.id}}

      assert %Server{next_action: %{params: %{ok: true, rev: 1}}} =
               VaultGate.command(
                 :create_vault,
                 %{blob: "v1.AAAA.BBBB", wrap: passphrase_wrap()},
                 owner_s
               )

      for {op, params} <- [
            {:fetch_vault, %{}},
            {:save_vault, %{base_rev: 1, blob: "v1.CCCC.DDDD"}},
            {:delete_vault, %{}},
            {:add_key_wrap, %{wrap: passkey_wrap()}}
          ] do
        assert %Server{next_action: %{params: %{ok: false, error: :forbidden}}} =
                 VaultGate.command(op, params, mem_s)
      end

      assert {:ok, %{rev: 1}} = Vaults.fetch(ws)
    end
  end

  describe "sharing off in E2EE mode (item 3)" do
    test "share_workspace and invitation fulfilment are refused" do
      enable_oidc()
      {owner, ws} = owner_ws("sh")
      enable_e2ee()

      assert {:error, _} = AccountOps.share_workspace(owner, ws, "x@example.com")

      assert {:error, :e2ee_sharing_disabled} =
               Accounts.share_workspace_with_email(ws, "x@example.com", owner)

      assert Accounts.list_pending_invitations(ws) == []
    end

    test "pending invitation is not fulfilled at login in E2EE mode" do
      enable_oidc()
      {owner, ws} = owner_ws("inv")
      {:ok, _} = Accounts.share_workspace_with_email(ws, "newbie@example.com", owner)
      enable_e2ee()
      newbie = oidc_user("newbie")
      refute Accounts.owner?(ws, newbie)
      assert [_] = Accounts.list_pending_invitations(ws)
      assert Accounts.list_workspaces_for_user(newbie) |> Enum.all?(&(&1.id != ws.id))
    end
  end

  describe "workspace switch in E2EE mode (item 4)" do
    test "replies with the account change and reload, no snapshot, no crash" do
      enable_oidc()
      enable_e2ee()
      {owner, ws} = owner_ws("sw")
      s = HeaderBar.command(:switch_workspace, %{workspace_id: ws.id}, server_for(owner))

      assert %Server{next_action: %{name: :account_changed, target: "page", params: p}} = s
      assert p.snapshot == nil
      assert p.reload == true
      assert p.modal == nil
    end

    test "save_settings in E2EE mode does not crash" do
      enable_oidc()
      enable_e2ee()
      {owner, _ws} = owner_ws("ss")

      params = %{display_name: "New Name", workspace_name: "Tracker", currency: "USD"}
      s = SettingsModal.command(:save_settings, params, server_for(owner))
      assert %Server{next_action: %{name: :account_changed, params: %{snapshot: nil}}} = s
    end
  end

  describe "boot seeding (item 5)" do
    test "does not seed in E2EE mode or when the workspace has a vault" do
      enable_e2ee()
      Boot.run()
      ws = Accounts.ensure_default_workspace!()
      assert Debts.list_debts(ws) == []
    end

    test "does not re-seed after a vault exists" do
      ws = Accounts.ensure_default_workspace!()
      {:ok, _} = Vaults.create(ws, "v1.AAAA.BBBB", passphrase_wrap())
      Debts.seed_placeholders_if_empty!(ws)
      assert Debts.list_debts(ws) == []
    end

    test "still seeds a fresh plaintext workspace" do
      ws = Accounts.ensure_default_workspace!()
      Debts.seed_placeholders_if_empty!(ws)
      assert Debts.list_debts(ws) != []
    end
  end

  describe "PHX_HOST in prod (item 6)" do
    @base %{enabled: true, oidc: false, vaults_exist: false}

    test "unset host is public in prod, local otherwise" do
      assert {:error, msg} = E2EE.check_boot(Map.merge(@base, %{host: nil, prod: true}))
      assert msg =~ "PHX_HOST"
      assert {:error, _} = E2EE.check_boot(Map.merge(@base, %{host: "", prod: true}))
      assert {:warn, _} = E2EE.check_boot(Map.merge(@base, %{host: nil, prod: false}))
      assert {:warn, _} = E2EE.check_boot(Map.merge(@base, %{host: "localhost", prod: true}))
      assert {:warn, _} = E2EE.check_boot(Map.merge(@base, %{host: "127.0.0.1", prod: true}))
    end
  end

  describe "request size limit (item 8)" do
    test "a ~7 MB body is rejected with 413", %{conn: conn} do
      big = String.duplicate("a", 7_000_000)

      assert_raise Plug.Parsers.RequestTooLargeError, fn ->
        conn
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> post("/hologram/command", ~s({"x":"#{big}"}))
      end
    end
  end
end
