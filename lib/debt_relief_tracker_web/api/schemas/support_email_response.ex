defmodule DebtReliefTrackerWeb.Api.Schemas.SupportEmailResponse do
  @moduledoc "Response body for `POST /api/support_emails`."

  require OpenApiSpex
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "SupportEmailResponse",
    type: :object,
    properties: %{
      id: %Schema{type: :string, format: :uuid},
      received_at: %Schema{type: :string, format: :"date-time"}
    },
    required: [:id, :received_at]
  })
end
