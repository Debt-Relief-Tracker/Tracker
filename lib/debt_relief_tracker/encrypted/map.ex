defmodule DebtReliefTracker.Encrypted.Map do
  @moduledoc """
  Encrypted replacement for `field :x, :map`. Used for
  `activity_logs.metadata`, which embeds plaintext debt names and payment
  amounts (see `DebtReliefTracker.Debts`/`DebtReliefTracker.Payments`) --
  encrypting `debts.name`/`payments.amount` while leaving this table's copy
  of the same data in plaintext would defeat most of the point.
  """

  use Cloak.Ecto.Map, vault: DebtReliefTracker.Vault
end
