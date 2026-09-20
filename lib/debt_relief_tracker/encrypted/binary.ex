defmodule DebtReliefTracker.Encrypted.Binary do
  @moduledoc """
  Encrypted replacement for `field :x, :string`. Named "Binary" after
  Cloak's own convention (the *column* is binary); the runtime value is a
  plain Elixir string, so callers, changesets, and `to_form/2` see exactly
  what `:string` gave them.
  """

  use Cloak.Ecto.Binary, vault: DebtReliefTracker.Vault
end
