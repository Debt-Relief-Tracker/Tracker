defmodule DebtReliefTracker.E2EE.MigrationRaceTest do
  # Real concurrency needs real (committed) connections, so this file leaves
  # the SQL sandbox, creates its own users and deletes them again in on_exit.
  # Never async: it flips the global sandbox mode.
  use ExUnit.Case, async: false

  import DebtReliefTracker.E2EEHelpers
  import DebtReliefTracker.MigrationHelpers
  import Ecto.Query

  alias DebtReliefTracker.{Debts, Payments, Repo}
  alias DebtReliefTracker.E2EE.Migration

  alias DebtReliefTracker.Accounts.User

  setup do
    repo = Repo.configured_repo()
    Ecto.Adapters.SQL.Sandbox.mode(repo, :auto)

    Application.put_env(:debt_relief_tracker, :oidc,
      issuer: "https://i",
      client_id: "c",
      client_secret: "s"
    )

    # Lazy code loading inside a SQLite write transaction can stall the whole
    # race (the code server is a single process): load everything up front.
    for app <- [
          :debt_relief_tracker,
          :plug_crypto,
          :elixir,
          :ecto,
          :ecto_sql,
          :exqlite,
          :ecto_sqlite3
        ],
        _ = Application.load(app),
        mod <- Application.spec(app, :modules) || [],
        do: Code.ensure_loaded(mod)

    # Also sweeps leftovers of an earlier crashed run (committed rows).
    purge()

    on_exit(fn ->
      Application.put_env(:debt_relief_tracker, :oidc, nil)
      Ecto.Adapters.SQL.Sandbox.mode(repo, :auto)
      purge()
      Ecto.Adapters.SQL.Sandbox.mode(repo, :manual)
    end)

    :ok
  end

  # Users (and, by FK cascade, their workspaces and everything in them).
  defp purge do
    ids = Repo.all(from(u in User, where: like(u.external_subject, "race-%"), select: u.id))
    Repo.delete_all(from(e in DebtReliefTracker.Accounts.SentEmail, where: e.user_id in ^ids))
    Repo.delete_all(from(u in User, where: u.id in ^ids))
  end

  defp fresh(tag) do
    {owner, ws} = owner_ws("race-#{tag}-#{System.unique_integer([:positive])}")
    populate!(ws, owner)
    create_vault!(ws)
    {:ok, export} = Migration.export(ws, owner)
    {owner, ws, export.digest}
  end

  defp safely(fun) do
    fun.()
  rescue
    e -> {:raised, e.__struct__, Exception.message(e)}
  end

  @tag :sqlite_only
  test "SQLite: compaction leaves no plaintext bytes in the database file or WAL" do
    repo = Repo.configured_repo()

    if repo == DebtReliefTracker.Repo.Sqlite do
      path = Keyword.fetch!(repo.config(), :database)
      files = fn -> for f <- [path, path <> "-wal"], File.exists?(f), do: File.read!(f) end
      has_marker? = fn -> Enum.any?(files.(), &String.contains?(&1, marker())) end

      {owner, ws, digest} = fresh("vac")
      # claim_email is the one plaintext column that carries the marker
      assert has_marker?.()

      assert {:ok, %{deleted: %{retirement_profiles: 1}}} = fin(ws, owner, digest)
      refute has_marker?.()
    end
  end

  defp sqlite?, do: Repo.configured_repo() == DebtReliefTracker.Repo.Sqlite

  # SQLite has one writer; under contention a loser may time out waiting
  # (raise) instead of seeing "already clean". That is acceptable ONLY because
  # the transaction rolled back: the state checks below prove it.
  defp acceptable_loser?({:ok, :already_clean}), do: true
  defp acceptable_loser?({:error, :changed}), do: true
  defp acceptable_loser?({:error, :busy}), do: true
  defp acceptable_loser?({:raised, _, _}), do: sqlite?()
  defp acceptable_loser?(_), do: false

  test "racing finalizes: exactly one deletes, the rest see nothing left" do
    {owner, ws, digest} = fresh("fin")
    racers = if sqlite?(), do: 2, else: 4
    vo = vopts(ws)

    results =
      1..racers
      |> Enum.map(fn _ ->
        Task.async(fn ->
          safely(fn -> Migration.finalize(ws, owner, digest, [compact: false] ++ vo) end)
        end)
      end)
      |> Task.await_many(60_000)

    {winners, losers} = Enum.split_with(results, &match?({:ok, %{deleted: _}}, &1))
    assert length(winners) <= 1
    assert Enum.all?(losers, &acceptable_loser?/1), inspect(losers)

    counts = table_counts(ws)

    case winners do
      [{:ok, %{deleted: %{debts: 1, payments: 1}}}] ->
        assert %{debts: 0, payments: 0, activity: 0, profiles: 0, vaults: 1} = counts

      [] ->
        # Only possible on SQLite lock timeouts: nothing may have changed.
        assert sqlite?()
        assert counts.debts == 1 and counts.payments == 1 and counts.profiles == 1
    end

    # PostgreSQL serializes on the row lock: exactly one winner, always.
    unless sqlite?(), do: assert(length(winners) == 1)
  end

  test "finalize racing payment writers is never partial and never loses a payment" do
    for round <- 1..if(sqlite?(), do: 2, else: 6) do
      {owner, ws, digest} = fresh("w#{round}")
      [debt] = Debts.list_debts(ws)

      writers =
        for i <- 1..2 do
          Task.async(fn ->
            Process.sleep(:rand.uniform(6) - 1)

            safely(fn ->
              Payments.log_payment(ws, nil, debt, %{
                "amount" => "1.0#{i}",
                "paid_on" => "2026-05-0#{i}"
              })
            end)
          end)
        end

      vo = vopts(ws)

      finalizer =
        Task.async(fn ->
          Process.sleep(:rand.uniform(6) - 1)
          safely(fn -> Migration.finalize(ws, owner, digest, [compact: false] ++ vo) end)
        end)

      result = Task.await(finalizer, 60_000)
      Task.await_many(writers, 60_000)
      counts = table_counts(ws)

      case result do
        # Deleted exactly what the digest covered (1 payment): a payment that
        # committed first would have changed the digest, and one arriving
        # later fails its foreign key. Nothing is left behind.
        {:ok, %{deleted: deleted}} ->
          assert deleted.payments == 1 and deleted.debts == 1
          assert %{debts: 0, payments: 0, activity: 0, profiles: 0, vaults: 1} = counts

        # Nothing at all was deleted.
        other ->
          assert other in [{:error, :changed}, {:error, :busy}] or
                   (match?({:raised, _, _}, other) and sqlite?()),
                 inspect(other)

          assert counts.debts == 1 and counts.profiles == 1 and counts.vaults == 1
          assert counts.payments >= 1
      end
    end
  end

  test "plaintext writers racing finalize can never re-create plaintext after the commit" do
    for round <- 1..if(sqlite?(), do: 2, else: 6) do
      {owner, ws, digest} = fresh("g#{round}")
      [debt] = Debts.list_debts(ws)
      vo = vopts(ws)

      writers =
        for i <- 1..3 do
          Task.async(fn ->
            Process.sleep(:rand.uniform(6) - 1)

            safely(fn ->
              case i do
                1 ->
                  Debts.create_debt(ws, owner, %{
                    "name" => "late#{round}",
                    "type" => "revolving",
                    "balance" => "5"
                  })

                2 ->
                  Payments.log_payment(ws, owner, debt, %{
                    "amount" => "1",
                    "paid_on" => "2026-05-01"
                  })

                3 ->
                  DebtReliefTracker.Settings.update_settings(
                    DebtReliefTracker.Settings.get_settings!(ws),
                    %{"currency" => "GBP"}
                  )
              end
            end)
          end)
        end

      finalizer =
        Task.async(fn ->
          Process.sleep(:rand.uniform(6) - 1)
          safely(fn -> Migration.finalize(ws, owner, digest, [compact: false] ++ vo) end)
        end)

      result = Task.await(finalizer, 60_000)
      writes = Task.await_many(writers, 60_000)

      # The vault exists from the start, so every writer is refused.
      for w <- writes do
        assert w == {:error, :workspace_encrypted} or (match?({:raised, _, _}, w) and sqlite?()),
               inspect(w)
      end

      # A later writer is refused too, and the end state is clean.
      assert {:error, :workspace_encrypted} =
               Debts.create_debt(ws, owner, %{
                 "name" => "after",
                 "type" => "revolving",
                 "balance" => "5"
               })

      case result do
        {:ok, %{deleted: _}} ->
          assert %{debts: 0, payments: 0, activity: 0, profiles: 0, vaults: 1} = table_counts(ws)

        other ->
          assert other in [{:error, :busy}] or (match?({:raised, _, _}, other) and sqlite?()),
                 inspect(other)

          assert %{debts: 1, payments: 1, profiles: 1} = table_counts(ws)
      end
    end
  end
end
