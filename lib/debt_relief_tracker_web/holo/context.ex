defmodule DebtReliefTrackerWeb.Holo.Context do
  @moduledoc """
  Server-only helpers for Hologram `init/3` and commands: the current user,
  workspace and the `Storage` call, all derived from what
  `DebtReliefTrackerWeb.Holo.Auth` stashed -- never from client params.
  """

  alias DebtReliefTracker.Accounts
  alias DebtReliefTracker.Storage
  alias DebtReliefTrackerWeb.OIDC

  def user(server) do
    case Hologram.Server.get_stash(server, :holo_user_id) do
      nil -> nil
      id -> Accounts.get_user!(id)
    end
  end

  def workspace(server) do
    case user(server) do
      nil -> Accounts.ensure_default_workspace!()
      user -> Accounts.current_workspace_for_user(user)
    end
  end

  def load(server), do: Storage.load(workspace(server))

  @doc """
  Today's date (UTC) as an ISO 8601 string. Hologram has no `Date` on the
  client, so server code (component `init/3`, commands) supplies "today" and
  the client works with the string / `Engine.Days` tuples.
  """
  def today_iso, do: Date.to_iso8601(Date.utc_today())

  @doc """
  Plain (non-financial) account data for the page: who is signed in, which
  workspace, whether OIDC is on. Lives beside the snapshot in page state but
  is never part of the E2EE vault -- it is account/session data.
  """
  def account(server) do
    user = user(server)
    profile_user = user || Accounts.get_default_user!()
    workspace = workspace(server)

    %{
      oidc_enabled: OIDC.enabled?(),
      signed_in: user != nil,
      user: %{
        id: profile_user.id,
        display_name: profile_user.display_name,
        email: profile_user.email,
        tutorial_seen: profile_user.tutorial_seen,
        theme: Map.get(profile_user, :theme),
        is_admin: profile_user.is_admin
      },
      workspace: %{id: workspace.id, name: workspace.name},
      workspaces:
        if(user,
          do: for(w <- Accounts.list_workspaces_for_user(user), do: %{id: w.id, name: w.name}),
          else: []
        )
    }
  end

  @doc """
  Applies a `Storage` change for the signed-in user's workspace. Returns
  `{:ok, snapshot}` or `{:error, error}` -- callers turn that into an action.
  """
  def apply_change(server, change),
    do: Storage.apply_change(workspace(server), user(server), change)
end
