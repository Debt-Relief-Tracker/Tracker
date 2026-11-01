defmodule DebtReliefTracker.E2EE do
  @moduledoc """
  The end-to-end encryption switch and its boot-time safety checks
  (docs/architecture/0007-e2ee.md).

  `enabled?/0` reads `config :debt_relief_tracker, :e2ee`, which
  `config/runtime.exs` sets once from the `E2EE` environment variable. Turning
  it on is irreversible in v1: there is no E2EE -> plaintext path.
  """

  require Logger

  alias DebtReliefTracker.E2EE.Vault
  alias DebtReliefTracker.Repo

  @local_hosts [nil, "", "localhost", "127.0.0.1"]

  @doc "Is E2EE mode on? Reads application config; false when unset."
  def enabled?, do: Application.get_env(:debt_relief_tracker, :e2ee, false) == true

  @doc """
  Parses the `E2EE` env value: "true"/"1"/"yes" (any case, surrounding
  whitespace ignored) is on; unset or anything else is off. `config/runtime.exs`
  applies the same rule inline (it cannot call app code).
  """
  def parse_flag(nil), do: false

  def parse_flag(value) when is_binary(value),
    do: value |> String.trim() |> String.downcase() |> Kernel.in(~w(true 1 yes))

  @doc """
  Decides whether the server may start. Pure, so it is unit tested:

    * E2EE on, OIDC off -> only for a single self-hosted user, i.e. `host`
      unset/`localhost`/`127.0.0.1` (returns `{:warn, message}`); any other host
      is `{:error, message}` (a public deployment must have OIDC).
    * E2EE off but vaults exist -> `{:error, message}`: never show an empty app.
  """
  def check_boot(%{enabled: enabled, oidc: oidc, host: host, vaults_exist: vaults_exist}) do
    cond do
      enabled and not oidc and host in @local_hosts ->
        {:warn,
         "E2EE is on without OIDC: anyone who can reach this server can read the " <>
           "ciphertext vault. Acceptable only for a single self-hosted user on localhost."}

      enabled and not oidc ->
        {:error,
         "E2EE=true requires OIDC on a hosted deployment (PHX_HOST=#{host}): without " <>
           "login the vault would be readable and writable by anyone. Configure " <>
           "OIDC_ISSUER/OIDC_CLIENT_ID/OIDC_CLIENT_SECRET, or run on localhost."}

      not enabled and vaults_exist ->
        {:error,
         "E2EE is off but encrypted vaults exist in the database. Refusing to start " <>
           "rather than show an empty app: set E2EE=true again. (E2EE cannot be " <>
           "turned off in v1.)"}

      true ->
        :ok
    end
  end

  @doc "Gathers the real inputs for `check_boot/1`; raises on `{:error, _}`."
  def check_boot! do
    enabled = enabled?()

    result =
      check_boot(%{
        enabled: enabled,
        oidc: DebtReliefTrackerWeb.OIDC.enabled?(),
        host: System.get_env("PHX_HOST"),
        vaults_exist: if(enabled, do: false, else: vaults_exist?())
      })

    case result do
      :ok -> :ok
      {:warn, message} -> Logger.warning(message)
      {:error, message} -> raise message
    end
  end

  # A missing table (dev, migrations not yet run) means no vaults.
  defp vaults_exist? do
    Repo.exists?(Vault)
  rescue
    e in [Exqlite.Error, Postgrex.Error] ->
      Logger.warning("could not check e2ee_vaults at boot: #{Exception.message(e)}")
      false
  end
end
