defmodule DebtReliefTracker.DataCase do
  @moduledoc """
  This module defines the setup for tests requiring
  access to the application's data layer.

  You may define functions here to be used as helpers in
  your tests.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. If you are using
  PostgreSQL, you can even run database tests asynchronously
  by setting `use DebtReliefTracker.DataCase, async: true`, although
  this option is not recommended for other databases.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      alias DebtReliefTracker.Repo

      import Ecto
      import Ecto.Changeset
      import Ecto.Query
      import DebtReliefTracker.DataCase
    end
  end

  setup tags do
    DebtReliefTracker.DataCase.setup_sandbox(tags)
    :ok
  end

  @doc """
  Sets up the sandbox based on the test tags.
  """
  def setup_sandbox(tags) do
    # Tests run against the concrete active repo (Sqlite by default, Postgres
    # when DATABASE_URL is set, see scripts/pg_test.sh) directly: the
    # DebtReliefTracker.Repo facade (docs/architecture/0001-dual-database-adapter.md)
    # is not itself an Ecto.Repo, so Sandbox needs the real module.
    pid =
      Ecto.Adapters.SQL.Sandbox.start_owner!(DebtReliefTracker.Repo.configured_repo(),
        shared: not tags[:async],
        ownership_timeout: Map.get(tags, :ownership_timeout, 120_000)
      )

    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
  end

  @doc """
  Shifts every existing activity-log entry of `workspace` `seconds` into the
  past. `activity_logs.inserted_at` is `timestamp(0)` on Postgres (the
  migration's plain `timestamps()`), so entries created within the same second
  tie there; tests asserting "most recent first" call this between actions to
  make the order deterministic on both adapters.
  """
  def backdate_activity(workspace, seconds \\ 60) do
    import Ecto.Query

    DebtReliefTracker.Repo.update_all(
      from(e in DebtReliefTracker.ActivityLog.Entry, where: e.workspace_id == ^workspace.id),
      set: [inserted_at: DateTime.add(DateTime.utc_now(), -seconds, :second)]
    )

    :ok
  end

  @doc """
  A helper that transforms changeset errors into a map of messages.

      assert {:error, changeset} = Accounts.create_user(%{password: "short"})
      assert "password is too short" in errors_on(changeset).password
      assert %{password: ["password is too short"]} = errors_on(changeset)

  """
  def errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
