defmodule DebtReliefTracker.Storage.Vault do
  @moduledoc """
  `DebtReliefTracker.Storage` for E2EE mode: the server holds only ciphertext
  and so can neither load nor change financial data. Both callbacks return
  `{:error, :e2ee_locked}`; the browser decrypts the vault, applies changes
  locally and uploads the re-encrypted blob through the vault commands
  (`DebtReliefTracker.E2EE.Vaults`).
  """

  @behaviour DebtReliefTracker.Storage

  @impl true
  def load(_workspace), do: {:error, :e2ee_locked}

  @impl true
  def apply_change(_workspace, _user, _change), do: {:error, :e2ee_locked}
end
