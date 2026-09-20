defmodule DebtReliefTrackerWeb.UserAuth do
  @moduledoc """
  `on_mount` hooks that resolve the session into an `Accounts.Scope` and
  assign it as `current_scope` (per the project's Phoenix 1.8 guidelines and
  `Layouts.app/1`'s `current_scope` attr), used by the router's `live_session`
  blocks.
  """

  use DebtReliefTrackerWeb, :verified_routes

  import Phoenix.Component
  import Phoenix.LiveView

  alias DebtReliefTracker.Accounts
  alias DebtReliefTracker.Accounts.Scope
  alias DebtReliefTrackerWeb.OIDC

  @doc """
  Assigns `current_scope`; redirects to `/auth/login` when OIDC is enabled
  and the session has no logged-in user. In no-auth mode everyone resolves
  to a `nil`-user scope, same as everywhere else in the app (ADR 0002).
  """
  def on_mount(:mount_current_scope, _params, session, socket) do
    case resolve_scope(session) do
      {:ok, scope} -> {:cont, assign(socket, :current_scope, scope)}
      :redirect -> {:halt, redirect(socket, to: ~p"/auth/login")}
    end
  end

  # Same as :mount_current_scope, but additionally requires Accounts.admin?/1
  # -- unless OIDC is disabled, since no-auth dev mode is already fully
  # trusted and should stay reachable without an IdP configured.
  @doc false
  def on_mount(:require_admin_scope, _params, session, socket) do
    case resolve_scope(session) do
      {:ok, scope} ->
        if not OIDC.enabled?() or Accounts.admin?(scope) do
          {:cont, assign(socket, :current_scope, scope)}
        else
          {:halt,
           socket
           |> put_flash(:error, "You don't have access to that page.")
           |> redirect(to: ~p"/")}
        end

      :redirect ->
        {:halt, redirect(socket, to: ~p"/auth/login")}
    end
  end

  defp resolve_scope(session) do
    cond do
      not OIDC.enabled?() -> {:ok, Scope.for_user(nil)}
      user_id = session["user_id"] -> {:ok, Scope.for_user(Accounts.get_user!(user_id))}
      true -> :redirect
    end
  end
end
