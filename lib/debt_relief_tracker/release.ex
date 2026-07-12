defmodule DebtReliefTracker.Release do
  @moduledoc """
  Used for executing DB release tasks when run in production without Mix
  installed.
  """
  @app :debt_relief_tracker

  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end
  end

  def rollback(repo, version) do
    load_app()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
  end

  # Only the repo config/runtime.exs actually activates (DATABASE_URL vs.
  # DATABASE_PATH, see docs/architecture/0001-dual-database-adapter.md) --
  # not `:ecto_repos`, which lists both Repo.Sqlite and Repo.Postgres so
  # `mix ecto.gen.migration` etc. know about both. Migrating the inactive
  # one would just fail to connect.
  defp repos do
    [DebtReliefTracker.Repo.configured_repo()]
  end

  defp load_app do
    # Many platforms require SSL when connecting to the database
    Application.ensure_all_started(:ssl)
    Application.ensure_loaded(@app)
  end
end
