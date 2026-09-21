defmodule DebtReliefTracker.Support.SupportEmail do
  @moduledoc """
  A record of an inbound email received at a support address, logged via
  `POST /api/support_emails` (docs/architecture/0006-support-api-and-tokens.md)
  by an external system (e.g. an inbound-email webhook), and shown in
  `DebtReliefTrackerWeb.AdminLive`'s "Support Emails" tab.

  `subject`/`body`/`metadata` are encrypted (docs/architecture/0005-field-level-encryption.md):
  support requests very plausibly restate the same financial detail
  (balances, lender names) the app otherwise protects. `from`/`to` stay
  plaintext, same reasoning as `users.email` -- they're routing/identity
  fields, not the sensitive content.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias DebtReliefTracker.Accounts.ApiToken
  alias DebtReliefTracker.Encrypted

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "support_emails" do
    field :from, :string
    field :to, :string
    field :subject, Encrypted.Binary, source: :subject_enc
    field :body, Encrypted.Binary, source: :body_enc
    field :metadata, Encrypted.Map, source: :metadata_enc
    field :received_at, :utc_datetime_usec

    belongs_to :api_token, ApiToken

    timestamps(updated_at: false, type: :utc_datetime_usec)
  end

  def changeset(support_email, attrs) do
    support_email
    |> cast(attrs, [:from, :to, :subject, :body, :metadata, :received_at, :api_token_id])
    |> put_default_metadata()
    |> validate_required([:from, :to, :subject, :body, :received_at])
  end

  defp put_default_metadata(changeset) do
    case get_field(changeset, :metadata) do
      nil -> put_change(changeset, :metadata, %{})
      _ -> changeset
    end
  end
end
