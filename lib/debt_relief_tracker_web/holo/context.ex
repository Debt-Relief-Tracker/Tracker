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
      # The header's workspace switcher stores its choice in the session;
      # `current_workspace_for_user/2` ignores a workspace the user doesn't
      # belong to, so a stale or forged id falls back to their first one.
      user -> Accounts.current_workspace_for_user(user, preferred_workspace_id(server))
    end
  end

  defp preferred_workspace_id(server) do
    case Hologram.Server.get_session(server, :workspace_id) do
      id when is_binary(id) -> id
      _ -> nil
    end
  end

  def load(server), do: Storage.load(workspace(server))

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
        theme: to_string(profile_user.preferences.theme),
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
