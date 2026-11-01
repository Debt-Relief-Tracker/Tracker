defmodule Mix.Tasks.Drt.AuditSnapshot do
  @shortdoc "Read-only: lists stored values the integer snapshot would round"

  @moduledoc """
  Reports every stored value that `DebtReliefTracker.Storage.Snapshot` would
  round (a balance with sub-cent digits, an APR or retirement percentage
  finer than 0.01%, a minimum-payment rate finer than 0.01%). Run it against
  a database *before* moving a plaintext workspace into the E2EE vault.

      mix drt.audit_snapshot

  Honours `DATABASE_URL` (Postgres) or `DATABASE_PATH` (SQLite) exactly like
  `config/runtime.exs`; with neither it uses the environment's configured
  database (dev: `data/debt_relief_tracker_dev.db`).

  Output, per workspace, the rows checked and one line per finding:

      table.column id=<uuid> decimals=<n> (would round to <value>)

  Names, notes and other personal data are never printed. Exit status 0 with a
  "no precision loss" line, or 1 when there are findings.

  ## Safety: this task never writes

  It deliberately does **not** start the application. That would run
  `Ecto.Migrator` (schema writes), `Boot.run/0` (seeds) and the
  `DuePayments.Scheduler` (which can post payments). Instead it starts only
  the database driver apps, `DebtReliefTracker.Vault` (to decrypt the
  columns) and the configured repo, and then only runs `SELECT`s:

    * SQLite opens the file with `mode: :readonly` (SQLite itself refuses any
      write; a missing file is an error rather than a new empty database);
    * Postgres connects with `default_transaction_read_only=on`.

  If the repo is already running (as in the test suite) it is used as is.
  """

  use Mix.Task

  require Logger

  alias DebtReliefTracker.PrecisionAudit
  alias DebtReliefTracker.Repo

  @impl Mix.Task
  def run(_args) do
    # Loads and compiles the project and evaluates config/runtime.exs; does
    # not start any application.
    Mix.Task.run("app.config")
    # Keep the report readable: no per-query debug logging.
    Logger.configure(level: :warning)

    repo = Repo.configured_repo()
    start_read_only!(repo)
    Repo.set_active_repo(repo)

    report = PrecisionAudit.run()
    for line <- PrecisionAudit.format(report), do: Mix.shell().info(line)

    if report.findings > 0, do: exit({:shutdown, 1}), else: :ok
  end

  @doc false
  # Starts only what reading needs -- never the full application.
  def start_read_only!(repo) do
    for app <- driver_apps(repo), do: {:ok, _} = Application.ensure_all_started(app)

    unless Process.whereis(DebtReliefTracker.Vault) do
      {:ok, _} = DebtReliefTracker.Vault.start_link()
    end

    unless Process.whereis(repo) do
      {:ok, _} = repo.start_link(read_only_opts(repo))
    end

    :ok
  end

  defp driver_apps(DebtReliefTracker.Repo.Sqlite), do: [:cloak_ecto, :ecto_sqlite3]
  defp driver_apps(DebtReliefTracker.Repo.Postgres), do: [:cloak_ecto, :ssl, :postgrex, :ecto_sql]

  @doc false
  def read_only_opts(DebtReliefTracker.Repo.Sqlite),
    do: [mode: :readonly, pool_size: 1, pool: DBConnection.ConnectionPool]

  def read_only_opts(DebtReliefTracker.Repo.Postgres),
    do: [
      pool_size: 2,
      pool: DBConnection.ConnectionPool,
      parameters: [default_transaction_read_only: "on"]
    ]
end
