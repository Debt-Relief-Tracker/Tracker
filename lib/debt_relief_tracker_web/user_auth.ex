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
      {:ok, scope} -> {:cont, assign_scope(socket, scope)}
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
          {:cont, assign_scope(socket, scope)}
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

  # Also bumps `last_seen_at` for the admin Users tab -- only on the
  # connected mount (not the static render), and throttled further in
  # Accounts.touch_last_seen/1. In no-auth mode the scope stays userless
  # (ADR 0002), but the implicit default user is the one actually using the
  # app, so it's touched instead.
  defp assign_scope(socket, scope) do
    scope =
      cond do
        not connected?(socket) ->
          scope

        scope.user ->
          %{scope | user: Accounts.touch_last_seen(scope.user)}

        true ->
          Accounts.touch_last_seen(Accounts.get_default_user!())
          scope
      end

    socket
    |> assign(:current_scope, scope)
    |> attach_hook(:theme_preference, :handle_event, &save_theme_preference/3)
  end

  # Handles the theme toggle's "set_theme" push (Layouts.theme_toggle/1) for
  # every LiveView in these live_sessions, so none of them need their own
  # handle_event. An invalid theme is just not saved -- the client has
  # already applied it locally either way.
  defp save_theme_preference("set_theme", %{"theme" => theme}, socket) do
    scope = socket.assigns.current_scope

    socket =
      case Accounts.update_preferences(Accounts.preferences_user(scope), %{theme: theme}) do
        {:ok, user} when scope.user != nil ->
          assign(socket, :current_scope, %{scope | user: user})

        _ ->
          socket
      end

    {:halt, socket}
  end

  defp save_theme_preference(_event, _params, socket), do: {:cont, socket}

  defp resolve_scope(session) do
    cond do
      not OIDC.enabled?() ->
        {:ok, Scope.for_user(nil)}

      (user_id = session["user_id"]) && match?({:ok, _}, Ecto.UUID.cast(user_id)) ->
        {:ok, Scope.for_user(Accounts.get_user!(user_id))}

      true ->
        :redirect
    end
  end
end
