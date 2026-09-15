defmodule DebtReliefTrackerWeb.OIDC do
  @moduledoc """
  Thin wrapper around Assent's generic OIDC strategy, configured from
  `OIDC_ISSUER` / `OIDC_CLIENT_ID` / `OIDC_CLIENT_SECRET`
  (docs/architecture/0002-auth-and-sharing-model.md).

  `enabled?/0` is the single gate the rest of the app checks: unset env vars
  means no login wall at all, by design.
  """

  @doc "Whether an OIDC provider is configured."
  def enabled?, do: config() != nil

  defp config, do: Application.get_env(:debt_relief_tracker, :oidc)

  @doc """
  Builds the provider's authorization URL to redirect the browser to.
  Returns `{:ok, %{url: url, session_params: session_params}}` --
  `session_params` (state/nonce/PKCE verifier) must be stashed in the plug
  session and passed back into `callback/3`.
  """
  def authorize_url(redirect_uri) do
    Assent.Strategy.OIDC.authorize_url(strategy_config(redirect_uri))
  end

  @doc """
  Exchanges the callback params for the authenticated user's claims, given
  the `session_params` `authorize_url/1` produced.
  """
  def callback(redirect_uri, params, session_params) do
    config = Keyword.put(strategy_config(redirect_uri), :session_params, session_params)

    with {:ok, %{user: user}} <- Assent.Strategy.OIDC.callback(config, params) do
      {:ok, user}
    end
  end

  defp strategy_config(redirect_uri) do
    cfg = config()

    [
      client_id: cfg[:client_id],
      client_secret: cfg[:client_secret],
      base_url: cfg[:issuer],
      redirect_uri: redirect_uri,
      authorization_params: [scope: "openid email profile"]
    ]
  end
end
