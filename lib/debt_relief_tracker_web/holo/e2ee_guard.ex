defmodule DebtReliefTrackerWeb.Holo.E2EEGuard do
  @moduledoc """
  The one server-side gate for the vault and migration commands. Hologram
  accepts any component module name and command from the client, so every
  command of `VaultGate` / `MigrationGate` is funnelled through
  `check/2` (their single public `command/3` calls it before dispatching).

    * `:enabled` -- E2EE must be on. With E2EE off these commands must have
      no side effect at all (a vault created in plaintext mode would make
      the next boot refuse to start).
    * `:owner` -- additionally, the session must be the workspace owner
      (no-auth mode: the implicit default user is the owner).
  """

  alias DebtReliefTracker.E2EE
  alias DebtReliefTrackerWeb.Holo.{AccountOps, Context}

  @doc "`:ok | {:error, :invalid | :forbidden}`."
  def check(_server, :enabled), do: if(E2EE.enabled?(), do: :ok, else: {:error, :invalid})

  def check(server, :owner) do
    with :ok <- check(server, :enabled) do
      if AccountOps.owner?(Context.workspace(server), Context.user(server)),
        do: :ok,
        else: {:error, :forbidden}
    end
  end
end
