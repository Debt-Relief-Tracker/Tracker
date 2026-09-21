defmodule DebtReliefTrackerWeb.Api.Schemas.SupportEmailRequest do
  @moduledoc "Request body for `POST /api/support_emails`."

  require OpenApiSpex
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "SupportEmailRequest",
    type: :object,
    properties: %{
      from: %Schema{type: :string, description: "Sender address", example: "user@example.com"},
      to: %Schema{
        type: :string,
        description: "Support address the email was sent to",
        example: "support@debtreliefapp.com"
      },
      subject: %Schema{type: :string},
      body: %Schema{type: :string},
      received_at: %Schema{
        type: :string,
        format: :"date-time",
        description: "When the email was actually sent/received"
      },
      metadata: %Schema{
        type: :object,
        description: "Arbitrary caller-supplied data",
        additionalProperties: true
      }
    },
    required: [:from, :to, :subject, :body, :received_at]
  })
end
