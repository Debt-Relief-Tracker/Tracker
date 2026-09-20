defmodule DebtReliefTracker.Encrypted.Integer do
  @moduledoc """
  Encrypted replacement for `field :x, :integer`.
  """

  use Cloak.Ecto.Integer, vault: DebtReliefTracker.Vault
end
