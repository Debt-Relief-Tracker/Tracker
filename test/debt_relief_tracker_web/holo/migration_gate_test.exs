defmodule DebtReliefTrackerWeb.Holo.Components.MigrationGateTest do
  # Not async: OIDC config is global.
  use DebtReliefTrackerWeb.ConnCase

  import DebtReliefTracker.E2EEHelpers
  import DebtReliefTracker.MigrationHelpers

  alias DebtReliefTracker.E2EE.{Migration, RateLimiter}
  alias DebtReliefTrackerWeb.Holo.Components.MigrationGate
  alias Hologram.Server

  setup do
    enable_oidc()
    enable_e2ee()
    RateLimiter.reset()
    {owner, ws} = owner_ws("own")
    populate!(ws, owner)
    %{owner: owner, ws: ws}
  end

  defp server_for(user), do: %Server{stash: %{holo_user_id: user.id}}

  defp run(user, name, params \\ %{}) do
    %Server{next_action: action} = MigrationGate.command(name, params, server_for(user))
    assert action.target == "page"
    assert action.name == String.to_atom("#{name}_result")
    assert action.params.op == name
    action.params
  end

  test "status reports the workspace status and ownership", %{owner: owner} do
    assert %{ok: true, status: :plaintext_only, owner: true} = run(owner, :migration_status)
  end

  test "export, dry run, vault, finalize through the commands", %{owner: owner, ws: ws} do
    member = share!(ws, owner, "mem")

    assert %{
             ok: true,
             snapshot: %{debts: [_]},
             digest: digest,
             members: [m],
             pending_invitations: 0
           } =
             run(owner, :migration_export)

    assert m.email == member.email

    assert %{ok: true, counts: %{debts: 1}, members_to_remove: [_]} =
             run(owner, :migration_dry_run)

    assert %{ok: false, error: :no_vault} =
             run(owner, :migration_finalize, %{
               digest: digest,
               confirm_remove_members: true,
               vault_rev: 1,
               vault_blob_sha256: String.duplicate("0", 64)
             })

    create_vault!(ws)

    vp = vault_params(ws)

    assert %{ok: false, error: :members_present} =
             run(owner, :migration_finalize, Map.put(vp, :digest, digest))

    assert %{ok: false, error: :changed} =
             run(
               owner,
               :migration_finalize,
               %{digest: "nope", confirm_remove_members: true} |> Map.merge(vp)
             )

    assert %{ok: false, error: :vault_changed} =
             run(owner, :migration_finalize, %{
               digest: digest,
               confirm_remove_members: true,
               vault_rev: vp.vault_rev,
               vault_blob_sha256: String.duplicate("0", 64)
             })

    assert %{ok: true, deleted: %{debts: 1}, removed_members: 1} =
             run(
               owner,
               :migration_finalize,
               Map.merge(vp, %{digest: digest, confirm_remove_members: true})
             )

    assert %{ok: true, already_clean: true} =
             run(
               owner,
               :migration_finalize,
               Map.merge(vp, %{digest: digest, confirm_remove_members: true})
             )

    assert Migration.status(ws) == :vault_only
    assert %{ok: false, error: :already_encrypted} = run(owner, :migration_export)
  end

  defp vault_params(ws) do
    Map.new(vopts(ws))
  end

  test "a non-owner member is forbidden and nothing changes", %{owner: owner, ws: ws} do
    member = share!(ws, owner, "mem")
    create_vault!(ws)
    %{digest: digest} = run(owner, :migration_export)

    # the member's session resolves to THEIR first workspace (their own, empty)
    assert %{ok: false, error: :nothing_to_migrate} = run(member, :migration_export)

    assert %{ok: true, status: :empty, owner: true} = run(member, :migration_status)
    assert Migration.status(ws) == :both
    assert Migration.digest(ws) == digest
  end

  test "client-supplied workspace ids and extra params are ignored", %{owner: owner, ws: ws} do
    {o2, ws2} = owner_ws("two")
    populate!(ws2, o2)
    create_vault!(ws2)
    %{digest: d2} = run(o2, :migration_export)

    # owner passes the OTHER workspace's id and digest: it only ever acts on its own
    assert %{ok: false, error: :no_vault} =
             run(owner, :migration_finalize, %{
               digest: d2,
               workspace_id: ws2.id,
               confirm_remove_members: true,
               vault_rev: 1,
               vault_blob_sha256: String.duplicate("0", 64)
             })

    assert Migration.status(ws2) == :both
    assert Migration.status(ws) == :plaintext_only
  end

  test "malformed params are a plain error", %{owner: owner} do
    assert %{ok: false, error: :invalid} = run(owner, :migration_finalize, %{})
    assert %{ok: false, error: :invalid} = run(owner, :migration_finalize, %{digest: 5})
  end

  test "export and finalize use a strict rate limit", %{owner: owner} do
    results = for _ <- 1..12, do: run(owner, :migration_export)
    assert Enum.count(results, &(&1[:error] == :rate_limited)) == 4
    # status is unaffected (normal bucket)
    assert %{ok: true} = run(owner, :migration_status)
  end

  test "the component carries the Auth middleware and redirects without a session" do
    assert Enum.any?(MigrationGate.__middleware__(), fn {capture, _} ->
             Function.info(capture, :module) == {:module, DebtReliefTrackerWeb.Holo.Auth}
           end)

    server = Hologram.Server.Middleware.run(%Server{}, MigrationGate.__middleware__())
    assert server.status == 302
  end

  test "no-auth mode: the implicit default user is the owner" do
    Application.put_env(:debt_relief_tracker, :oidc, nil)
    ws = DebtReliefTracker.Accounts.ensure_default_workspace!()
    populate!(ws, DebtReliefTracker.Accounts.get_default_user!())
    server = %Server{stash: %{holo_user_id: nil}}
    %Server{next_action: action} = MigrationGate.command(:migration_export, %{}, server)
    assert %{ok: true, digest: _} = action.params
  end
end
