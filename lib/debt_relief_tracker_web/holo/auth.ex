defmodule DebtReliefTrackerWeb.Holo.Auth do
  @moduledoc """
  Hologram middleware for the dashboard (the LiveView `:mount_current_scope`
  hook it replaced is gone): resolves the Phoenix session's `user_id` (set by the OIDC callback; Hologram
  runs on the Phoenix session) and stashes it as `:holo_user_id`. With OIDC
  off everyone is the implicit no-auth user (ADR 0002, stash `nil`).

  Attach it to every page *and* every stateful component that defines
  commands -- Hologram's middleware does not cascade from a page to its
  components' commands. Commands then derive the workspace from the stash via
  `DebtReliefTrackerWeb.Holo.Context`, never from client-supplied ids.

  Also bumps `last_seen_at` for the admin Users tab (throttled inside
  `Accounts.touch_last_seen/1`; in no-auth mode the implicit default user).
  """

  use Hologram.Middleware

  alias DebtReliefTracker.Accounts
  alias DebtReliefTrackerWeb.OIDC

  def call(server, _opts) do
    if OIDC.enabled?() do
      case user_id(server) do
        nil -> put_redirect(server, "/auth/login")
        user_id -> put_stash(server, :holo_user_id, user_id)
      end
    else
      Accounts.touch_last_seen(Accounts.get_default_user!())
      put_stash(server, :holo_user_id, nil)
    end
  end

  defp user_id(server) do
    with id when is_binary(id) <- get_session(server, :user_id),
         {:ok, id} <- Ecto.UUID.cast(id),
         %Accounts.User{} = user <- Accounts.get_user(id) do
      Accounts.touch_last_seen(user)
      id
    else
      _ -> nil
    end
  end
end
