defmodule DebtReliefTrackerWeb.Api.Spec do
  @moduledoc """
  OpenAPI spec for the admin API (docs/architecture/0006-support-api-and-tokens.md).
  Served as JSON at `/api/openapi` and as interactive docs at
  `/api/swaggerui`.
  """

  alias OpenApiSpex.{Components, Info, OpenApi, Paths, SecurityScheme, Server}

  @behaviour OpenApi

  @impl OpenApi
  def spec do
    %OpenApi{
      servers: [Server.from_endpoint(DebtReliefTrackerWeb.Endpoint)],
      info: %Info{
        title: "Debt Relief Tracker Admin API",
        version: "1.0",
        description: "Machine-to-machine endpoints for admin-managed integrations."
      },
      paths: Paths.from_router(DebtReliefTrackerWeb.Router),
      components: %Components{
        securitySchemes: %{
          "bearerAuth" => %SecurityScheme{
            type: "http",
            scheme: "bearer",
            description: "An API token created from /admin?tab=tokens, e.g. \"Bearer drt_...\"."
          }
        }
      },
      security: [%{"bearerAuth" => []}]
    }
    |> OpenApiSpex.resolve_schema_modules()
  end
end
