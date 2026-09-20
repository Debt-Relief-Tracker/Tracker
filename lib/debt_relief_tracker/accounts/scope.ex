defmodule DebtReliefTracker.Accounts.Scope do
  @moduledoc """
  The current request/session identity, resolved once by
  `DebtReliefTrackerWeb.UserAuth`'s `on_mount` hooks and threaded through
  `current_scope` (see `DebtReliefTrackerWeb.Layouts.app/1`). `user` is `nil`
  in no-auth mode (ADR 0002), same as everywhere else in the app.
  """

  alias DebtReliefTracker.Accounts.User

  defstruct user: nil

  def for_user(%User{} = user), do: %__MODULE__{user: user}
  def for_user(nil), do: %__MODULE__{user: nil}
end
