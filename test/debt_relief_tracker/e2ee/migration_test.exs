defmodule DebtReliefTracker.E2EE.MigrationTest do
  # Not async: OIDC config and the shared sandbox.
  use DebtReliefTracker.DataCase

  import DebtReliefTracker.E2EEHelpers
  import DebtReliefTracker.MigrationHelpers
  import ExUnit.CaptureIO

  alias DebtReliefTracker.{Accounts, ActivityLog, Debts, Payments, Repo, Settings}
  alias DebtReliefTracker.E2EE.{Migration, Vaults}
  alias DebtReliefTracker.Settings.Setting
  alias Mix.Tasks.Drt.AuditSnapshot

  setup do
    enable_oidc()
    {owner, ws} = owner_ws("own")
    %{owner: owner, ws: ws}
  end

  defp export!(ws, owner) do
    {:ok, export} = Migration.export(ws, owner)
    export
  end

  describe "status/1" do
    test "empty, plaintext_only, both, vault_only", %{owner: owner, ws: ws} do
      assert Migration.status(ws) == :empty

      populate!(ws, owner)
      assert Migration.status(ws) == :plaintext_only

      create_vault!(ws)
      assert Migration.status(ws) == :both

      {:ok, e} = Migration.export(ws, owner)
      assert {:ok, %{}} = fin(ws, owner, e.digest, confirm_remove_members: true)
      assert Migration.status(ws) == :vault_only
    end

    test "each kind of plaintext row counts on its own", %{owner: owner, ws: ws} do
      # the default settings row alone is not plaintext
      Settings.get_settings!(ws)
      assert Migration.status(ws) == :empty

      {:ok, _} = Settings.update_settings(Settings.get_settings!(ws), %{"currency" => "EUR"})
      assert Migration.status(ws) == :plaintext_only
      {:ok, _} = Settings.update_settings(Settings.get_settings!(ws), %{"currency" => "USD"})
      assert Migration.status(ws) == :empty

      {:ok, _} =
        Settings.update_settings(Settings.get_settings!(ws), %{"budget_mode" => "margin"})

      assert Migration.status(ws) == :plaintext_only
      {:ok, _} = Settings.update_settings(Settings.get_settings!(ws), %{"budget_mode" => "total"})

      {:ok, _} = Settings.update_settings(Settings.get_settings!(ws), %{"monthly_budget" => "5"})
      assert Migration.status(ws) == :plaintext_only
      {:ok, _} = Settings.update_settings(Settings.get_settings!(ws), %{"monthly_budget" => nil})
      assert Migration.status(ws) == :empty

      {:ok, _} = ActivityLog.record(ws, owner, :debt_added)
      assert Migration.status(ws) == :plaintext_only
    end

    test "statuses/0 and status_counts/0 cover every workspace", %{owner: owner, ws: ws} do
      {_o2, ws2} = owner_ws("two")
      {o3, ws3} = owner_ws("three")
      populate!(ws, owner)
      populate!(ws3, o3)
      create_vault!(ws3)
      create_vault!(ws2)

      statuses = Migration.statuses()
      assert statuses[ws.id] == :plaintext_only
      assert statuses[ws2.id] == :vault_only
      assert statuses[ws3.id] == :both
      assert %{plaintext_only: 1, vault_only: 1, both: 1} = Migration.status_counts()
    end
  end

  describe "digest" do
    test "is stable across calls, processes and re-loads", %{owner: owner, ws: ws} do
      populate!(ws, owner)
      d1 = export!(ws, owner).digest
      assert d1 == export!(ws, owner).digest
      assert d1 == Migration.digest(ws)

      assert d1 ==
               Task.async(fn -> Migration.digest(Accounts.get_workspace!(ws.id)) end)
               |> Task.await()

      assert d1 =~ ~r/\A[0-9a-f]{64}\z/
    end

    test "differs per workspace even for identical data", %{owner: owner, ws: ws} do
      {o2, ws2} = owner_ws("two")
      populate!(ws, owner)
      populate!(ws2, o2)
      refute Migration.digest(ws) == Migration.digest(ws2)
    end

    test "canonical form ignores map ordering but is unambiguous" do
      assert Migration.canonical(%{a: 1, b: 2}) == Migration.canonical(%{"b" => 2, "a" => 1})
      refute Migration.canonical(["ab", "c"]) == Migration.canonical(["a", "bc"])
      refute Migration.canonical(%{"a" => nil}) == Migration.canonical(%{"a" => "nil"})
      refute Migration.canonical(1) == Migration.canonical("1")
      refute Migration.canonical([[1], 2]) == Migration.canonical([1, [2]])
      assert_raise ArgumentError, fn -> Migration.canonical({:a}) end
      assert_raise ArgumentError, fn -> Migration.canonical(~D[2026-01-01]) end
    end

    test "changes on every kind of plaintext change", %{owner: owner, ws: ws} do
      %{debt: debt, payment: payment, profile: profile} = populate!(ws, owner)
      backdate_activity(ws)
      digest = fn -> Migration.digest(ws) end

      changes = [
        {"balance edit", fn -> Debts.update_debt(ws, owner, debt, %{"balance" => "1000.00"}) end},
        {"debt rename", fn -> Debts.update_debt(ws, owner, debt, %{"name" => "Other"}) end},
        {"new payment",
         fn ->
           Payments.log_payment(ws, owner, debt, %{"amount" => "5", "paid_on" => "2026-02-01"})
         end},
        {"payment note edit",
         fn ->
           payment
           |> Ecto.Changeset.change(note: "edited")
           |> DebtReliefTracker.Repo.update()
         end},
        {"activity entry",
         fn -> ActivityLog.record(ws, owner, :debt_updated, debt, %{"x" => 1}) end},
        {"budget",
         fn ->
           Settings.update_settings(Settings.get_settings!(ws), %{"monthly_budget" => "9"})
         end},
        {"currency",
         fn -> Settings.update_settings(Settings.get_settings!(ws), %{"currency" => "GBP"}) end},
        {"budget mode",
         fn ->
           Settings.update_settings(Settings.get_settings!(ws), %{"budget_mode" => "margin"})
         end},
        {"onboarding flag",
         fn ->
           Settings.update_settings(Settings.get_settings!(ws), %{
             "retirement_onboarding_dismissed" => true
           })
         end},
        {"retirement edit",
         fn -> Settings.update_retirement_profile(profile, %{"current_age" => "31"}) end},
        {"retirement add",
         fn ->
           Settings.add_manual_retirement_profile(ws, %{
             "name" => "Third",
             "current_age" => "40",
             "retirement_age" => "65",
             "current_retirement_savings" => "0",
             "monthly_retirement_contribution" => "0",
             "monthly_gross_income" => "0",
             "post_debt_investment_pct" => "0",
             "expected_annual_return_pct" => "0"
           })
         end},
        {"mark paid off", fn -> Debts.mark_paid_off(ws, owner, debt) end},
        {"retirement delete", fn -> Settings.delete_retirement_profile(profile) end},
        {"payment delete", fn -> DebtReliefTracker.Repo.delete(payment) end},
        {"debt delete", fn -> Debts.delete_debt(ws, owner, debt) end}
      ]

      Enum.reduce(changes, digest.(), fn {label, change}, previous ->
        change.()
        now = digest.()
        refute now == previous, "digest did not change after: #{label}"
        now
      end)
    end

    test "another workspace's changes do not affect it", %{owner: owner, ws: ws} do
      {o2, ws2} = owner_ws("two")
      populate!(ws, owner)
      before = Migration.digest(ws)
      populate!(ws2, o2)
      assert Migration.digest(ws) == before
    end
  end

  describe "export/2" do
    test "returns the plaintext snapshot, digest, people and invitation count", %{
      owner: owner,
      ws: ws
    } do
      %{debt: debt} = populate!(ws, owner)
      member = share!(ws, owner, "mem")
      invite!(ws, owner, "ghost@example.com")

      assert {:ok, export} = Migration.export(ws, owner)
      assert [%{id: id}] = export.snapshot.debts
      assert id == debt.id
      assert export.members == [%{display_name: member.display_name, email: member.email}]
      assert export.pending_invitations == 1
      assert {:ok, export.snapshot} == DebtReliefTracker.Storage.Plain.load(ws)
    end

    test "owner only", %{owner: owner, ws: ws} do
      populate!(ws, owner)
      member = share!(ws, owner, "mem")
      stranger = oidc_user("stranger")

      for other <- [member, stranger, nil] do
        assert {:error, :forbidden} = Migration.export(ws, other)
        assert {:error, :forbidden} = Migration.dry_run(ws, other)

        assert {:error, :forbidden} =
                 fin(ws, other, "x", confirm_remove_members: true)
      end

      # a stale/forged workspace struct claiming another owner does not help either
      forged = %{ws | owner_user_id: stranger.id}
      assert {:error, :forbidden} = Migration.export(forged, stranger)

      assert {:error, :forbidden} = Migration.dry_run(forged, stranger)
    end

    test ":empty and :vault_only are refused; :both is allowed", %{owner: owner, ws: ws} do
      assert {:error, :nothing_to_migrate} = Migration.export(ws, owner)
      populate!(ws, owner)
      create_vault!(ws)
      assert {:ok, _} = Migration.export(ws, owner)
      {:ok, e} = Migration.export(ws, owner)
      {:ok, %{}} = fin(ws, owner, e.digest)
      assert {:error, :already_encrypted} = Migration.export(ws, owner)
    end

    test "works in no-auth mode for the implicit default user" do
      Application.put_env(:debt_relief_tracker, :oidc, nil)
      ws = Accounts.ensure_default_workspace!()
      user = Accounts.get_default_user!()
      populate!(ws, user)
      assert {:ok, _} = Migration.export(ws, user)
    end
  end

  describe "dry_run/2" do
    test "lists counts and the people who would lose access without changing anything",
         %{owner: owner, ws: ws} do
      populate!(ws, owner)
      member = share!(ws, owner, "mem")
      invite!(ws, owner, "ghost@example.com")
      create_vault!(ws)
      before = {table_counts(ws), Migration.digest(ws)}

      assert {:ok, report} = Migration.dry_run(ws, owner)
      assert report.counts == %{debts: 1, payments: 1, activity: 2, retirement_profiles: 1}

      assert report.members_to_remove == [
               %{display_name: member.display_name, email: member.email}
             ]

      assert report.pending_invitations == 1
      assert {table_counts(ws), Migration.digest(ws)} == before
    end
  end

  describe "finalize/4" do
    setup %{owner: owner, ws: ws} do
      populate!(ws, owner)
      %{digest: export!(ws, owner).digest}
    end

    test "refuses without a vault and deletes nothing", %{owner: owner, ws: ws, digest: digest} do
      before = table_counts(ws)

      assert {:error, :no_vault} =
               fin(ws, owner, digest, confirm_remove_members: true)

      assert table_counts(ws) == before
      assert Migration.digest(ws) == digest
    end

    test "refuses a wrong, malformed or nil digest", %{owner: owner, ws: ws, digest: digest} do
      create_vault!(ws)
      before = table_counts(ws)

      for bad <- ["", "x", String.duplicate("0", 64), nil, 5, String.upcase(digest) <> "0"] do
        assert {:error, :changed} =
                 fin(ws, owner, bad, confirm_remove_members: true)
      end

      assert table_counts(ws) == before
    end

    test "a payment posted after the export (via log_payment) makes it :changed",
         %{owner: owner, ws: ws, digest: digest} do
      create_vault!(ws)
      [debt] = Debts.list_debts(ws)

      {:ok, _} =
        Payments.log_payment(ws, nil, debt, %{"amount" => "10", "paid_on" => "2026-03-01"})

      before = table_counts(ws)

      assert {:error, :changed} =
               fin(ws, owner, digest, confirm_remove_members: true)

      assert table_counts(ws) == before

      # re-export, then it goes through
      %{digest: fresh} = export!(ws, owner)
      assert {:ok, %{deleted: %{payments: 2}}} = fin(ws, owner, fresh)
    end

    test "a payment posted by the scheduler after the export makes it :changed",
         %{owner: owner, ws: ws} do
      {:ok, _} =
        Debts.create_debt(ws, owner, %{
          "name" => "Auto",
          "type" => "installment",
          "balance" => "1000.00",
          "apr" => "5.00",
          "fixed_payment" => "100.00",
          "auto_log_mode" => "automatic",
          "due_day" => to_string(Date.utc_today().day)
        })

      %{digest: digest} = export!(ws, owner)
      create_vault!(ws)
      # simulate the old behaviour: the scheduler path called directly
      [auto] = Enum.filter(Debts.list_debts(ws), &(&1.name == "Auto"))
      {:ok, _} = DebtReliefTracker.DuePayments.post_due_payment(ws, nil, auto)

      assert {:error, :changed} =
               fin(ws, owner, digest, confirm_remove_members: true)
    end

    test "members and invitations need explicit confirmation", %{owner: owner, ws: ws} do
      member = share!(ws, owner, "mem")
      invite!(ws, owner, "ghost@example.com")
      create_vault!(ws)
      %{digest: digest} = export!(ws, owner)
      before = table_counts(ws)

      for opts <- [
            [],
            [confirm_remove_members: false],
            [confirm_remove_members: "true"],
            [confirm_remove_members: 1]
          ] do
        assert {:error, :members_present} = fin(ws, owner, digest, opts)
      end

      assert table_counts(ws) == before

      assert {:ok, %{removed_members: 1, canceled_invitations: 1}} =
               fin(ws, owner, digest, confirm_remove_members: true)

      assert Accounts.list_workspace_members(ws) == []
      assert Accounts.list_pending_invitations(ws) == []
      assert Accounts.owner?(ws, owner)
      # the removed member keeps their own workspace and account
      assert Accounts.get_user(member.id)
      assert Accounts.list_workspaces_for_user(member) != []
      refute ws in Accounts.list_workspaces_for_user(member)
      assert ws in Accounts.list_workspaces_for_user(owner)
    end

    test "no members: no confirmation needed", %{owner: owner, ws: ws, digest: digest} do
      create_vault!(ws)

      assert {:ok, %{removed_members: 0, canceled_invitations: 0}} =
               fin(ws, owner, digest)
    end

    test "deletes every plaintext row; the marker is nowhere afterwards",
         %{owner: owner, ws: ws, digest: digest} do
      create_vault!(ws)
      {:ok, vault_before} = Vaults.fetch(ws)
      assert dump_all() =~ marker()
      # the plaintext claim_email column is the raw-searchable witness; the
      # decrypted dump covers the Cloak columns
      assert dump_all() =~ "Card #{marker()}"

      assert {:ok, summary} = fin(ws, owner, digest)

      assert summary == %{
               deleted: %{debts: 1, payments: 1, activity: 2, retirement_profiles: 1},
               removed_members: 0,
               canceled_invitations: 0
             }

      refute dump_all() =~ marker()

      assert %{debts: 0, activity: 0, profiles: 0, payments: 0, vaults: 1} = table_counts(ws)

      # settings row shell kept, values reset
      setting = Settings.get_settings!(ws)
      assert setting.monthly_budget == nil
      assert setting.currency == "USD"
      assert setting.budget_mode == :total
      assert DebtReliefTracker.Repo.get_by(Setting, workspace_id: ws.id)

      # workspace, owner, membership and vault untouched
      assert Accounts.get_workspace!(ws.id).name == ws.name
      assert ws in Accounts.list_workspaces_for_user(owner)
      assert {:ok, vault_after} = Vaults.fetch(ws)
      assert vault_after == vault_before
      assert Migration.status(ws) == :vault_only
    end

    test "never touches another workspace, even with shared members",
         %{owner: owner, ws: ws, digest: digest} do
      {o2, ws2} = owner_ws("two")
      populate!(ws2, o2, "OTHERMARK")
      member = share!(ws, owner, "mem")
      # the member also belongs to the other workspace; the other's invitation too
      {:ok, _} = Accounts.share_workspace_with_email(ws2, member.email, o2)
      invite!(ws2, o2, "ghost2@example.com")
      create_vault!(ws)
      create_vault!(ws2)
      before2 = {table_counts(ws2), Migration.digest(ws2), Vaults.fetch(ws2)}

      assert {:ok, %{removed_members: 1}} =
               fin(ws, owner, digest, confirm_remove_members: true)

      assert {table_counts(ws2), Migration.digest(ws2), Vaults.fetch(ws2)} == before2
      assert ws2 in Accounts.list_workspaces_for_user(member)
      assert dump_all() =~ "OTHERMARK"
    end

    test "is idempotent", %{owner: owner, ws: ws, digest: digest} do
      create_vault!(ws)
      assert {:ok, %{deleted: _}} = fin(ws, owner, digest)
      assert {:ok, :already_clean} = fin(ws, owner, digest)
      assert {:ok, :already_clean} = fin(ws, owner, "anything")
    end

    test "a failure inside the transaction rolls EVERYTHING back", %{
      owner: owner,
      ws: ws,
      digest: digest
    } do
      member = share!(ws, owner, "mem")
      invite!(ws, owner, "ghost@example.com")
      create_vault!(ws)
      before = {table_counts(ws), Migration.digest(ws), Vaults.fetch(ws), Migration.status(ws)}

      assert_raise RuntimeError, "boom", fn ->
        fin(ws, owner, digest,
          confirm_remove_members: true,
          before_commit: fn -> raise "boom" end
        )
      end

      assert {table_counts(ws), Migration.digest(ws), Vaults.fetch(ws), Migration.status(ws)} ==
               before

      assert Migration.digest(ws) == digest
      assert Accounts.list_workspace_members(ws) |> length() == 1
      assert Accounts.list_pending_invitations(ws) |> length() == 1
      assert ws in Accounts.list_workspaces_for_user(member)
      assert Settings.get_settings!(ws).currency == "EUR"
      assert dump_all() =~ marker()

      # and a clean retry still works
      assert {:ok, %{deleted: %{debts: 1}}} =
               fin(ws, owner, digest, confirm_remove_members: true)
    end

    test "a member who is demoted/forged is not the owner", %{
      owner: owner,
      ws: ws,
      digest: digest
    } do
      member = share!(ws, owner, "mem")
      create_vault!(ws)
      forged = %{ws | owner_user_id: member.id}

      assert {:error, :forbidden} =
               fin(forged, member, digest, confirm_remove_members: true)

      assert Migration.status(ws) == :both
    end

    test "mix drt.audit_snapshot (read-only) still passes after a migration",
         %{owner: owner, ws: ws, digest: digest} do
      create_vault!(ws)
      {:ok, _} = fin(ws, owner, digest)
      out = capture_io(fn -> AuditSnapshot.run([]) end)
      assert out =~ "no precision loss"
    end
  end

  describe "finalize is bound to the verified vault" do
    setup do
      {owner, ws} = owner_ws("bind")
      populate!(ws, owner)
      create_vault!(ws)
      {:ok, e} = Migration.export(ws, owner)
      %{owner: owner, ws: ws, digest: e.digest}
    end

    test "wrong hash, wrong rev, missing options: :vault_changed and nothing deleted",
         %{owner: owner, ws: ws, digest: digest} do
      good = vopts(ws)
      before = {table_counts(ws), Migration.digest(ws), Migration.status(ws)}

      for opts <- [
            [],
            [vault_rev: good[:vault_rev]],
            [vault_rev: good[:vault_rev], vault_blob_sha256: blob_sha("v1.other.blob")],
            [vault_rev: good[:vault_rev] + 1, vault_blob_sha256: good[:vault_blob_sha256]],
            [vault_rev: "1", vault_blob_sha256: good[:vault_blob_sha256]],
            [vault_rev: good[:vault_rev], vault_blob_sha256: 5]
          ] do
        assert {:error, :vault_changed} = Migration.finalize(ws, owner, digest, opts)
      end

      assert {table_counts(ws), Migration.digest(ws), Migration.status(ws)} == before
    end

    test "a vault overwritten after verification blocks the delete",
         %{owner: owner, ws: ws, digest: digest} do
      good = vopts(ws)

      vault = Repo.get!(DebtReliefTracker.E2EE.Vault, ws.id)

      vault
      |> Ecto.Changeset.change(blob: "v1.CCCC.DDDD", rev: vault.rev + 1)
      |> Repo.update!()

      assert {:error, :vault_changed} = Migration.finalize(ws, owner, digest, good)
      assert Migration.status(ws) == :both
    end

    test "the matching rev and hash delete", %{owner: owner, ws: ws, digest: digest} do
      assert {:ok, %{deleted: %{debts: 1}}} =
               Migration.finalize(ws, owner, digest, vopts(ws))

      assert Migration.status(ws) == :vault_only
    end
  end
end
