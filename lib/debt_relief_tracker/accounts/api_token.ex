defmodule DebtReliefTracker.Accounts.ApiToken do
  @moduledoc """
  A machine-to-machine credential for the admin API
  (docs/architecture/0006-support-api-and-tokens.md). Created/revoked from
  `DebtReliefTrackerWeb.AdminLive`'s "API Tokens" tab.

  Only `token_hash` (a SHA-256 digest) is ever persisted -- the raw token is
  generated, shown to the admin exactly once, and never stored, so a
  database leak alone can't be used to authenticate. This is deliberately
  *not* Cloak encryption (docs/architecture/0005-field-level-encryption.md):
  encryption is reversible by design, which is wrong for a secret we never
  need to read back, only compare.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias DebtReliefTracker.Accounts.User
  alias DebtReliefTracker.Types.StringList

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @known_scopes ~w(support_emails:write)

  schema "api_tokens" do
    field :name, :string
    field :token_hash, :string
    field :last_four, :string
    field :scopes, StringList, default: []
    field :last_used_at, :utc_datetime_usec
    field :revoked_at, :utc_datetime_usec

    belongs_to :created_by, User, foreign_key: :created_by_user_id

    timestamps(type: :utc_datetime_usec)
  end

  def known_scopes, do: @known_scopes

  @doc """
  Validates the admin-supplied half of a new token (`name`, `scopes`) --
  used both to back the "new token" form and as the first step of
  `Accounts.create_api_token/2`, so a raw token is only ever generated once
  these fields are already known to be valid.
  """
  def changeset(api_token, attrs) do
    api_token
    |> cast(attrs, [:name, :scopes])
    |> validate_required([:name])
    |> validate_scopes()
  end

  # `[]` is `scopes`'s schema default, so a submitted empty list is never
  # recorded as a "change" from the struct's starting value -- validate_required/
  # validate_change (both change-tracked) would silently pass it. Checking
  # get_field/2 directly, unconditionally, is the same pattern
  # RetirementProfile.validate_retirement_age_after_current_age/1 uses for the
  # same reason.
  defp validate_scopes(changeset) do
    scopes = get_field(changeset, :scopes) || []
    unknown = Enum.reject(scopes, &(&1 in @known_scopes))

    cond do
      scopes == [] ->
        add_error(changeset, :scopes, "can't be blank")

      unknown != [] ->
        add_error(changeset, :scopes, "contains unknown scope(s): #{Enum.join(unknown, ", ")}")

      true ->
        changeset
    end
  end

  @doc "Adds the generated credential fields to an already-validated `changeset/2` result, ready to insert."
  def put_generated(changeset, %{token_hash: token_hash, last_four: last_four} = generated) do
    changeset
    |> put_change(:token_hash, token_hash)
    |> put_change(:last_four, last_four)
    |> put_change(:created_by_user_id, generated[:created_by_user_id])
    |> validate_required([:token_hash, :last_four])
    |> unique_constraint(:token_hash)
  end

  @doc "Marks the token revoked -- soft delete, so the admin UI retains an audit trail."
  def revoke_changeset(api_token) do
    change(api_token, revoked_at: DateTime.utc_now())
  end

  @doc "Records that the token was just used to authenticate a request."
  def touch_changeset(api_token) do
    change(api_token, last_used_at: DateTime.utc_now())
  end

  def revoked?(%__MODULE__{revoked_at: nil}), do: false
  def revoked?(%__MODULE__{revoked_at: %DateTime{}}), do: true

  @doc "Whether `scope` is among this token's granted scopes."
  def has_scope?(%__MODULE__{scopes: scopes}, scope), do: scope in scopes
end
