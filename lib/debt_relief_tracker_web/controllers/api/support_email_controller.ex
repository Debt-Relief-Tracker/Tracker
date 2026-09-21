defmodule DebtReliefTrackerWeb.Api.SupportEmailController do
  @moduledoc """
  Admin API endpoint for logging an inbound support email
  (docs/architecture/0006-support-api-and-tokens.md). Requires a bearer
  token with the `support_emails:write` scope -- see
  `DebtReliefTrackerWeb.Plugs.ApiAuth`.
  """

  use DebtReliefTrackerWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias DebtReliefTracker.Support
  alias DebtReliefTrackerWeb.Api.Schemas.{SupportEmailRequest, SupportEmailResponse}

  plug OpenApiSpex.Plug.CastAndValidate, json_render_error_v2: true

  tags(["support_emails"])
  security([%{"bearerAuth" => []}])

  operation(:create,
    summary: "Log an inbound support email",
    request_body: {"Support email", "application/json", SupportEmailRequest, required: true},
    responses: [
      created: {"Logged", "application/json", SupportEmailResponse},
      unprocessable_entity: {"Validation error", "application/json", %OpenApiSpex.Schema{}}
    ]
  )

  def create(conn, _params) do
    attrs =
      conn.body_params
      |> Map.from_struct()
      |> Map.put(:api_token_id, conn.assigns.api_token.id)

    case Support.log_support_email(attrs) do
      {:ok, support_email} ->
        conn
        |> put_status(:created)
        |> json(%{id: support_email.id, received_at: support_email.received_at})

      {:error, changeset} ->
        errors =
          Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
            Enum.reduce(opts, msg, fn {key, value}, acc ->
              String.replace(acc, "%{#{key}}", to_string(value))
            end)
          end)

        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: errors})
    end
  end
end
