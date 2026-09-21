defmodule DebtReliefTracker.Support do
  @moduledoc """
  Inbound support-email logging, received via the admin API
  (docs/architecture/0006-support-api-and-tokens.md) and shown in
  `DebtReliefTrackerWeb.AdminLive`'s "Support Emails" tab.
  """

  import Ecto.Query, warn: false

  alias DebtReliefTracker.Repo
  alias DebtReliefTracker.Support.SupportEmail

  @doc "Logs an inbound support email. `attrs` may include `api_token_id` to record which token logged it."
  def log_support_email(attrs) do
    %SupportEmail{}
    |> SupportEmail.changeset(attrs)
    |> Repo.insert()
  end

  @doc "Every logged support email, newest received first, for the admin log."
  def list_support_emails(limit \\ 100) do
    from(e in SupportEmail, order_by: [desc: e.received_at], limit: ^limit)
    |> Repo.all()
  end

  @doc "Fetches a support email log entry by id."
  def get_support_email!(id), do: Repo.get!(SupportEmail, id)
end
