defmodule DebtReliefTracker.Accounts.SentEmail do
  @moduledoc """
  A record of every email `UserNotifier` has sent, for the admin sent-email
  log (`DebtReliefTrackerWeb.AdminLive`). `metadata` carries whatever
  `Accounts.resend_email!/1` needs to rebuild and redeliver the same email.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias DebtReliefTracker.Accounts.User

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "sent_emails" do
    field :template, Ecto.Enum, values: [:welcome, :workspace_shared, :workspace_invitation]
    field :to, :string
    field :subject, :string
    field :status, Ecto.Enum, values: [:sent, :failed]
    field :error, :string
    field :metadata, :map, default: %{}

    belongs_to :user, User

    timestamps(updated_at: false)
  end

  def changeset(sent_email, attrs) do
    sent_email
    |> cast(attrs, [:template, :to, :subject, :status, :error, :metadata, :user_id])
    |> validate_required([:template, :to, :subject, :status])
  end
end
