defmodule DebtReliefTracker.E2EE.KeyWrap do
  @moduledoc """
  The vault key wrapped by one unlock method (passphrase, passkey or recovery
  key). The id is client-chosen (a UUID) because the wrap's AAD binds it, so
  the browser must know it before encrypting. All fields are opaque to the server: `wrapped_key` is the facade's
  `v1.<iv>.<ct>` envelope (the IV lives inside it). Validation here is shape
  and size only -- the server cannot check that a wrap is cryptographically
  valid, and never tries to. Sensitive fields are `redact: true`.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @kinds ~w(passphrase passkey recovery)

  schema "e2ee_key_wraps" do
    field :workspace_id, :binary_id
    field :kind, :string
    field :label, :string
    field :credential_id, :string, redact: true
    field :kdf_params, :string, redact: true
    field :salt, :string, redact: true
    field :wrapped_key, :string, redact: true

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def kinds, do: @kinds

  @doc "Max sizes (bytes) of the wrap fields; enforced in the changeset."
  def limits,
    do: %{label: 100, credential_id: 1024, kdf_params: 512, salt: 128, wrapped_key: 1024}

  def changeset(wrap, attrs) do
    wrap
    |> cast(attrs, [:id, :kind, :label, :credential_id, :kdf_params, :salt, :wrapped_key])
    |> validate_required([:id, :kind, :wrapped_key])
    |> validate_inclusion(:kind, @kinds)
    |> validate_format(:wrapped_key, ~r/\Av1\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\z/)
    |> validate_format(:credential_id, ~r/\A[A-Za-z0-9_-]+\z/)
    |> validate_format(:salt, ~r/\A[A-Za-z0-9_-]+\z/)
    |> validate_kind_fields()
    |> validate_sizes()
    |> unique_constraint(:credential_id, name: :e2ee_key_wraps_workspace_id_credential_id_index)
  end

  defp validate_kind_fields(changeset) do
    case get_field(changeset, :kind) do
      "passkey" -> validate_required(changeset, [:credential_id])
      "passphrase" -> validate_required(changeset, [:salt, :kdf_params])
      _ -> changeset
    end
  end

  defp validate_sizes(changeset) do
    Enum.reduce(limits(), changeset, fn {field, max}, cs ->
      validate_length(cs, field, max: max, count: :bytes)
    end)
  end
end
