defmodule DebtReliefTracker.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    if Application.get_env(:debt_relief_tracker, :preload_modules, false), do: preload_modules()

    active_repo = DebtReliefTracker.Repo.configured_repo()
    DebtReliefTracker.Repo.set_active_repo(active_repo)

    children = [
      DebtReliefTrackerWeb.Telemetry,
      # Must start before active_repo/the Migrator: the encryption backfill
      # migration and every DebtReliefTracker.Encrypted.* field need the
      # vault running to encrypt/decrypt.
      DebtReliefTracker.Vault,
      active_repo,
      {Ecto.Migrator, repos: [active_repo], skip: skip_migrations?()},
      {DNSCluster,
       query: Application.get_env(:debt_relief_tracker, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: DebtReliefTracker.PubSub},
      DebtReliefTracker.E2EE.RateLimiter,
      DebtReliefTracker.DuePayments.Scheduler,
      # Start to serve requests, typically the last entry
      DebtReliefTrackerWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: DebtReliefTracker.Supervisor]

    with {:ok, pid} <- Supervisor.start_link(children, opts) do
      if Application.get_env(:debt_relief_tracker, :run_boot_tasks, true) do
        DebtReliefTracker.Boot.run()
      end

      {:ok, pid}
    end
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    DebtReliefTrackerWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  defp skip_migrations?() do
    # By default, sqlite migrations are run when using a release
    System.get_env("RELEASE_NAME") == nil
  end

  # Hologram decodes a command's component/function names with
  # `String.to_existing_atom/1`, so a component whose module hasn't loaded yet
  # (e.g. a modal nobody has opened) fails its first command with "not an
  # already existing atom". Releases load every module at boot; dev loads them
  # lazily, so dev (config/dev.exs) opts in to loading them up front.
  defp preload_modules do
    {:ok, modules} = :application.get_key(:debt_relief_tracker, :modules)
    Enum.each(modules, &Code.ensure_loaded/1)
  end
end
