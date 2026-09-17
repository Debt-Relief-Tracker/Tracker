defmodule DebtReliefTracker.Accounts do
  @moduledoc """
  Users, workspaces, and workspace membership.

  See docs/architecture/0002-auth-and-sharing-model.md: a `Workspace` (not a
  `User`) is the unit debts/payments/settings belong to, so that sharing a
  workspace with another logged-in user (once OIDC is configured, Phase 7)
  doesn't require a data-model migration.
  """

  import Ecto.Query, warn: false

  alias DebtReliefTracker.Repo

  alias DebtReliefTracker.Accounts.{
    User,
    Workspace,
    WorkspaceMember,
    WorkspaceInvitation,
    UserNotifier
  }

  @doc """
  Returns the single implicit user/workspace used in no-auth mode, creating
  it on first boot if it doesn't exist yet. Idempotent -- safe to call on
  every application start.
  """
  def ensure_default_workspace! do
    get_owned_workspace!(get_default_user!())
  end

  @doc """
  Returns the single implicit `User` used in no-auth mode (identified by a
  `nil` `external_subject`), creating it and its own workspace on first boot
  if it doesn't exist yet. Idempotent -- safe to call any time.
  """
  def get_default_user! do
    case Repo.one(from(u in User, where: is_nil(u.external_subject))) do
      nil ->
        {user, _workspace} =
          create_user_with_own_workspace!(
            %{display_name: "You", external_subject: nil},
            "My Debts"
          )

        user

      %User{} = user ->
        user
    end
  end

  @doc "Fetches a user by id."
  def get_user!(id), do: Repo.get!(User, id)

  @doc """
  Marks whether `user` has seen the dashboard's onboarding tutorial. Used
  both to record completion/skip and to reset it via "View tutorial again."
  """
  def set_tutorial_seen(%User{} = user, seen?) do
    user
    |> User.tutorial_changeset(%{tutorial_seen: seen?})
    |> Repo.update()
  end

  @doc """
  Finds or creates the `User` for an OIDC identity (matched on the
  provider's `sub` claim), creating their own workspace on first login
  (docs/architecture/0002-auth-and-sharing-model.md). Returns the user.
  """
  def get_or_create_user_from_oidc!(%{"sub" => subject} = claims) do
    case Repo.get_by(User, external_subject: subject) do
      %User{} = user ->
        user

      nil ->
        display_name = claims["name"] || claims["email"] || "New user"

        user_attrs = %{
          display_name: display_name,
          external_subject: subject,
          email: claims["email"]
        }

        {user, _workspace} =
          create_user_with_own_workspace!(user_attrs, "#{display_name}'s Debts")

        fulfill_pending_invitations(user)
        user
    end
  end

  # Turns any pending invitations addressed to this email into real
  # WorkspaceMember access, now that the invitee has an account. Only
  # relevant on first login: share_workspace_with_email/3 only ever creates
  # an invitation when no matching User exists yet, so an existing user
  # never has invitations left to fulfill.
  defp fulfill_pending_invitations(%User{email: nil}), do: :ok

  defp fulfill_pending_invitations(%User{email: email} = user) do
    from(i in WorkspaceInvitation, where: i.email == ^email)
    |> Repo.all()
    |> Enum.each(fn invitation ->
      Repo.transaction(fn ->
        {:ok, _member} =
          %WorkspaceMember{}
          |> WorkspaceMember.changeset(%{
            workspace_id: invitation.workspace_id,
            user_id: user.id,
            role: :member
          })
          |> Repo.insert()

        {:ok, _} = Repo.delete(invitation)
      end)
    end)

    :ok
  end

  # Returns `{user, workspace}` -- both are needed by the two callers above,
  # which each only want one half.
  defp create_user_with_own_workspace!(user_attrs, workspace_name) do
    Repo.transaction(fn ->
      {:ok, user} = %User{} |> User.changeset(user_attrs) |> Repo.insert()

      {:ok, workspace} =
        %Workspace{}
        |> Workspace.changeset(%{name: workspace_name, owner_user_id: user.id})
        |> Repo.insert()

      {:ok, _member} =
        %WorkspaceMember{}
        |> WorkspaceMember.changeset(%{
          workspace_id: workspace.id,
          user_id: user.id,
          role: :owner
        })
        |> Repo.insert()

      {user, workspace}
    end)
    |> case do
      {:ok, {user, workspace}} -> {user, workspace}
    end
  end

  defp get_owned_workspace!(%User{id: user_id}) do
    Repo.get_by!(Workspace, owner_user_id: user_id)
  end

  @doc "Fetches a workspace by id."
  def get_workspace!(id), do: Repo.get!(Workspace, id)

  @doc """
  Every workspace in the system, regardless of owner -- used by
  `DuePayments.Scheduler` to sweep for due auto-log payments across every
  user's data, not just workspaces with an open LiveView connection.
  """
  def list_workspaces, do: Repo.all(Workspace)

  @doc "Lists the workspaces a user owns or is a member of."
  def list_workspaces_for_user(%User{id: user_id}) do
    from(w in Workspace,
      join: m in WorkspaceMember,
      on: m.workspace_id == w.id,
      where: m.user_id == ^user_id,
      order_by: w.name
    )
    |> Repo.all()
  end

  @doc """
  The workspace a user should currently see: `preferred_id` if they belong
  to it, otherwise their first workspace (owned or shared with them).
  """
  def current_workspace_for_user(%User{} = user, preferred_id \\ nil) do
    workspaces = list_workspaces_for_user(user)
    Enum.find(workspaces, List.first(workspaces), &(&1.id == preferred_id))
  end

  @doc "Whether a user owns a given workspace."
  def owner?(%Workspace{owner_user_id: owner_id}, %User{id: user_id}), do: owner_id == user_id

  @doc """
  Shares `workspace` with `email` (docs/architecture/0002-auth-and-sharing-model.md:
  an explicit grant, not attribution). If a `User` with that email has
  already logged in once, grants them member access immediately and emails
  them. If not, creates a pending `WorkspaceInvitation` and emails the
  address a sign-in link; it's fulfilled automatically the first time that
  email completes OIDC login (see `get_or_create_user_from_oidc!/1`).
  """
  def share_workspace_with_email(%Workspace{} = workspace, email, %User{} = inviter) do
    case Repo.get_by(User, email: email) do
      nil ->
        %WorkspaceInvitation{}
        |> WorkspaceInvitation.changeset(%{
          workspace_id: workspace.id,
          email: email,
          invited_by_user_id: inviter.id
        })
        |> Repo.insert()
        |> tap(fn
          {:ok, invitation} ->
            UserNotifier.deliver_workspace_invitation(invitation, workspace, inviter)

          {:error, _changeset} ->
            :ok
        end)

      %User{} = user ->
        %WorkspaceMember{}
        |> WorkspaceMember.changeset(%{
          workspace_id: workspace.id,
          user_id: user.id,
          role: :member
        })
        |> Repo.insert()
        |> tap(fn
          {:ok, _member} -> UserNotifier.deliver_workspace_shared(user, workspace, inviter)
          {:error, _changeset} -> :ok
        end)
    end
  end

  @doc "Pending invitations for a workspace, oldest first."
  def list_pending_invitations(%Workspace{id: workspace_id}) do
    from(i in WorkspaceInvitation,
      where: i.workspace_id == ^workspace_id,
      order_by: i.inserted_at
    )
    |> Repo.all()
  end

  @doc """
  Cancels a pending invitation belonging to `workspace`. `{:error, :not_found}`
  if it's already gone (accepted or previously canceled).
  """
  def cancel_invitation(%Workspace{id: workspace_id}, invitation_id) do
    case Repo.get_by(WorkspaceInvitation, id: invitation_id, workspace_id: workspace_id) do
      nil -> {:error, :not_found}
      invitation -> Repo.delete(invitation)
    end
  end

  @doc "Renames `workspace`. Caller is responsible for authorizing the rename."
  def update_workspace(%Workspace{} = workspace, attrs) do
    workspace
    |> Workspace.rename_changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Accepted members of a workspace, excluding the owner's own membership row,
  oldest first, preloaded with :user.
  """
  def list_workspace_members(%Workspace{id: workspace_id}) do
    from(m in WorkspaceMember,
      where: m.workspace_id == ^workspace_id and m.role != :owner,
      order_by: m.inserted_at,
      preload: :user
    )
    |> Repo.all()
  end

  @doc """
  Removes a member's access to `workspace`. `{:error, :not_found}` if already
  gone; `{:error, :cannot_remove_owner}` if `member_id` resolves to the
  workspace's own owner row.
  """
  def remove_member(%Workspace{id: workspace_id}, member_id) do
    case Repo.get_by(WorkspaceMember, id: member_id, workspace_id: workspace_id) do
      nil -> {:error, :not_found}
      %WorkspaceMember{role: :owner} -> {:error, :cannot_remove_owner}
      member -> Repo.delete(member)
    end
  end
end
