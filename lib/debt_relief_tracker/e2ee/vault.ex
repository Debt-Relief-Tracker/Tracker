defmodule DebtReliefTracker.E2EE.Vault do
  @moduledoc """
  One workspace's encrypted document (docs/architecture/0007-e2ee.md). `blob`
  is an opaque `v1.<iv>.<ct>` envelope held as bytes; the server never parses
  it. `rev` is the compare-and-swap counter. Sensitive columns are
  `redact: true` so `inspect/1` and crash reports never dump them.
  """

  use Ecto.Schema

  @primary_key {:workspace_id, :binary_id, autogenerate: false}
  @foreign_key_type :binary_id

  schema "e2ee_vaults" do
    field :rev, :integer, default: 1
    field :blob, :binary, redact: true
    field :format_version, :integer, default: 1

    timestamps(type: :utc_datetime_usec)
  end
end
