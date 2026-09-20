defmodule DebtReliefTracker.ActivityLog do
  @moduledoc """
  Records every mutating debt/payment action, per docs/plan.md Phase 3: "each
  needs to be a logged action." Called from inside the relevant `Debts`/
  `Payments` context function (never from the UI layer), so an entry can't be
  skipped by forgetting a call at the call site.
  """

  import Ecto.Query, warn: false

  alias DebtReliefTracker.Repo
  alias DebtReliefTracker.Accounts.{User, Workspace}
  alias DebtReliefTracker.Debts.Debt
  alias DebtReliefTracker.ActivityLog.Entry

  @doc """
  Records an activity log entry. `user` and `debt` are optional (nil is
  allowed) since some actions aren't tied to a specific debt, and the actor
  isn't known in no-auth mode.
  """
  def record(%Workspace{} = workspace, user, action, debt \\ nil, metadata \\ %{})
      when action in [
             :debt_added,
             :debt_updated,
             :debt_paid_off,
             :debt_deleted,
             :payment_logged,
             :payment_auto_logged,
             :due_payment_skipped
           ] do
    %Entry{}
    |> Entry.changeset(%{
      workspace_id: workspace.id,
      user_id: user_id(user),
      debt_id: debt_id(debt),
      action: action,
      metadata: metadata
    })
    |> Repo.insert()
  end

  defp user_id(%User{id: id}), do: id
  defp user_id(nil), do: nil

  defp debt_id(%Debt{id: id}), do: id
  defp debt_id(nil), do: nil

  @doc """
  Lists recent activity for a workspace, most recent first. Preloads `:user`
  and `:debt` since both are shown in the activity log UI (`:debt` is `nil`
  for a `:debt_deleted` entry -- see `Debts.delete_debt/3`). Ties on
  `inserted_at` (same-second timestamp precision, easy to hit when several
  actions happen in quick succession) break on `:id` descending, so ordering
  is at least deterministic across page reloads -- ids are UUIDs, so this
  tiebreak is an arbitrary-but-stable order within a same-second tie, not an
  approximation of insertion order (see the UUID primary-key migration).
  """
  def list_recent(%Workspace{id: workspace_id}, limit \\ 50) do
    from(e in Entry,
      where: e.workspace_id == ^workspace_id,
      order_by: [desc: e.inserted_at, desc: e.id],
      limit: ^limit,
      preload: [:user, :debt]
    )
    |> Repo.all()
  end
end
