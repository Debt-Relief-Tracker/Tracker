defmodule DebtReliefTrackerWeb.Plugs.ApiAuth do
  @moduledoc """
  Bearer-token auth for the admin API (docs/architecture/0006-support-api-and-tokens.md).
  Takes `scope:` in its plug opts -- the scope string the presented token
  must carry (see `DebtReliefTracker.Accounts.ApiToken.known_scopes/0`).

  On success, assigns `conn.assigns.api_token`. On failure, halts with a
  `401` JSON error body.
  """

  import Plug.Conn

  alias DebtReliefTracker.Accounts

  def init(opts), do: Keyword.fetch!(opts, :scope)

  def call(conn, required_scope) do
    with ["Bearer " <> raw_token] <- get_req_header(conn, "authorization"),
         {:ok, api_token} <- Accounts.authenticate_token(raw_token, required_scope) do
      assign(conn, :api_token, api_token)
    else
      _ -> unauthorized(conn)
    end
  end

  defp unauthorized(conn) do
    conn
    |> put_status(:unauthorized)
    |> Phoenix.Controller.json(%{errors: ["missing or invalid API token"]})
    |> halt()
  end
end
