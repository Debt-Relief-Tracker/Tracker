defmodule DebtReliefTracker.Repo do
  @moduledoc """
  Forwards to whichever real `Ecto.Repo` (`Repo.Sqlite` or `Repo.Postgres`) is
  active for this boot, per docs/architecture/0001-dual-database-adapter.md.

  Ecto fixes a repo's adapter at compile time, so a single `Ecto.Repo` can't
  switch between SQLite and Postgres based on a runtime env var. Instead,
  both real repos are compiled in, and `DebtReliefTracker.Application` starts
  only the active one and records the choice here via `:persistent_term`
  before any query can run.

  Only the subset of `Ecto.Repo`'s API the app actually calls is forwarded.
  """

  @doc """
  The concrete `Ecto.Repo` module selected by `config/runtime.exs` (via the
  `:ecto_adapter` config it sets from `DATABASE_URL` vs `DATABASE_PATH`).
  Reads plain `Application` config, so it works before the supervision tree
  has started -- used both by `Application.start/2` (to know which repo to
  start) and by `DebtReliefTracker.Release.migrate/0` (which runs as a
  separate one-off release command, before `bin/server` boots the app).
  """
  def configured_repo do
    case Application.fetch_env!(:debt_relief_tracker, :ecto_adapter) do
      :postgres -> DebtReliefTracker.Repo.Postgres
      :sqlite -> DebtReliefTracker.Repo.Sqlite
    end
  end

  @doc false
  def set_active_repo(repo)
      when repo in [DebtReliefTracker.Repo.Sqlite, DebtReliefTracker.Repo.Postgres] do
    :persistent_term.put({__MODULE__, :active_repo}, repo)
  end

  @doc "The concrete `Ecto.Repo` module active for this boot."
  def active_repo, do: :persistent_term.get({__MODULE__, :active_repo})

  def all(queryable, opts \\ []), do: active_repo().all(queryable, opts)
  def one(queryable, opts \\ []), do: active_repo().one(queryable, opts)
  def one!(queryable, opts \\ []), do: active_repo().one!(queryable, opts)
  def get(queryable, id, opts \\ []), do: active_repo().get(queryable, id, opts)
  def get!(queryable, id, opts \\ []), do: active_repo().get!(queryable, id, opts)
  def get_by(queryable, clauses, opts \\ []), do: active_repo().get_by(queryable, clauses, opts)
  def get_by!(queryable, clauses, opts \\ []), do: active_repo().get_by!(queryable, clauses, opts)

  def insert(struct_or_changeset, opts \\ []), do: active_repo().insert(struct_or_changeset, opts)

  def insert!(struct_or_changeset, opts \\ []),
    do: active_repo().insert!(struct_or_changeset, opts)

  def update(changeset, opts \\ []), do: active_repo().update(changeset, opts)
  def update!(changeset, opts \\ []), do: active_repo().update!(changeset, opts)
  def delete(struct_or_changeset, opts \\ []), do: active_repo().delete(struct_or_changeset, opts)

  def delete!(struct_or_changeset, opts \\ []),
    do: active_repo().delete!(struct_or_changeset, opts)

  def insert_all(schema_or_source, entries, opts \\ []),
    do: active_repo().insert_all(schema_or_source, entries, opts)

  def update_all(queryable, updates, opts \\ []),
    do: active_repo().update_all(queryable, updates, opts)

  def delete_all(queryable, opts \\ []), do: active_repo().delete_all(queryable, opts)

  def transaction(fun_or_multi, opts \\ []), do: active_repo().transaction(fun_or_multi, opts)
  def rollback(value), do: active_repo().rollback(value)

  def preload(struct_or_structs_or_nil, preloads, opts \\ []),
    do: active_repo().preload(struct_or_structs_or_nil, preloads, opts)

  def aggregate(queryable, aggregate, opts \\ []),
    do: active_repo().aggregate(queryable, aggregate, opts)

  def aggregate(queryable, aggregate, field, opts),
    do: active_repo().aggregate(queryable, aggregate, field, opts)

  def exists?(queryable, opts \\ []), do: active_repo().exists?(queryable, opts)
end
