defmodule DebtReliefTracker.Encrypted.Decimal do
  @moduledoc """
  Encrypted replacement for `field :x, :decimal`.
  """

  use Cloak.Ecto.Decimal, vault: DebtReliefTracker.Vault
end
