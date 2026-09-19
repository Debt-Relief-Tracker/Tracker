defmodule DebtReliefTrackerWeb.AuthController do
  @moduledoc """
  The optional OIDC login flow (docs/architecture/0002-auth-and-sharing-model.md).
  These routes exist regardless of whether OIDC is configured, but no-op
  back to "/" when it isn't -- `DebtReliefTrackerWeb.OIDC.enabled?/0` is the
  single source of truth `DashboardLive` also checks.
  """

  use DebtReliefTrackerWeb, :controller

  alias DebtReliefTracker.Accounts
  alias DebtReliefTrackerWeb.OIDC

  def login(conn, _params) do
    if OIDC.enabled?() do
      case OIDC.authorize_url(url(~p"/auth/callback")) do
        {:ok, %{url: url, session_params: session_params}} ->
          conn
          |> put_session(:oidc_session_params, session_params)
          |> redirect(external: url)

        {:error, _reason} ->
          conn
          |> put_flash(:error, "Could not reach the login provider. Try again shortly.")
          |> redirect(to: ~p"/")
      end
    else
      redirect(conn, to: ~p"/")
    end
  end

  def callback(conn, params) do
    if OIDC.enabled?() do
      session_params = get_session(conn, :oidc_session_params) || %{}

      case OIDC.callback(url(~p"/auth/callback"), params, session_params) do
        {:ok, claims} ->
          user = Accounts.get_or_create_user_from_oidc!(claims)

          conn
          |> delete_session(:oidc_session_params)
          |> put_session(:user_id, user.id)
          |> redirect(to: ~p"/")

        {:error, _reason} ->
          conn
          |> put_flash(:error, "Login failed. Please try again.")
          |> redirect(to: ~p"/")
      end
    else
      conn
      |> put_flash(:error, "Login failed. Please try again.")
      |> redirect(to: ~p"/")
    end
  end

  def logout(conn, _params) do
    conn
    |> configure_session(drop: true)
    |> redirect(to: ~p"/")
  end
end
