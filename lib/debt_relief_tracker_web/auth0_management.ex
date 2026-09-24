defmodule DebtReliefTrackerWeb.Auth0Management do
  @moduledoc """
  Writes a user's display name back to Auth0 via its Management API, so the
  IdP stays the source of truth for names edited in the app (see
  `DebtReliefTracker.Accounts.update_display_name/2`).

  Entirely optional and Auth0-specific, like `OIDC.auth0_logout_url/1`: it
  needs a separate Machine-to-Machine application (`AUTH0_MGMT_CLIENT_ID` /
  `AUTH0_MGMT_CLIENT_SECRET`, authorized for the Management API with only
  `update:users`) -- see README's "Auth0 setup". With those unset, OIDC still
  works and names are edited locally only.

  A fresh M2M token is fetched per call rather than cached: name edits are
  rare, and this avoids a process just to hold a token.
  """

  @doc "Whether Management API credentials are configured."
  def enabled?, do: config() != nil

  defp config, do: Application.get_env(:debt_relief_tracker, :auth0_management)

  @doc "Sets `name` on the Auth0 user identified by `sub`. Returns `:ok` or `{:error, reason}`."
  def update_name(sub, name) do
    with {:ok, token} <- fetch_token() do
      case Req.patch(req(),
             url: "/api/v2/users/#{URI.encode(sub, &URI.char_unreserved?/1)}",
             auth: {:bearer, token},
             json: %{name: name}
           ) do
        {:ok, %Req.Response{status: 200}} -> :ok
        {:ok, %Req.Response{status: status, body: body}} -> {:error, {status, body}}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp fetch_token do
    cfg = config()

    case Req.post(req(),
           url: "/oauth/token",
           json: %{
             grant_type: "client_credentials",
             client_id: cfg[:client_id],
             client_secret: cfg[:client_secret],
             audience: "#{base_url()}/api/v2/"
           }
         ) do
      {:ok, %Req.Response{status: 200, body: %{"access_token" => token}}} -> {:ok, token}
      {:ok, %Req.Response{status: status, body: body}} -> {:error, {status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp req do
    Req.new(
      [base_url: base_url(), retry: false] ++
        Application.get_env(:debt_relief_tracker, :auth0_req_options, [])
    )
  end

  defp base_url, do: String.trim_trailing(config()[:domain], "/")
end
