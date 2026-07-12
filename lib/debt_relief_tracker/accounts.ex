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
  alias DebtReliefTracker.Accounts.{User, Workspace, WorkspaceMember}

  @doc """
  Returns the single implicit user/workspace used in no-auth mode, creating
  it on first boot if it doesn't exist yet. Idempotent -- safe to call on
  every application start.
  """
  def ensure_default_workspace! do
    case Repo.one(from(u in User, where: is_nil(u.external_subject))) do
      nil ->
        {_user, workspace} =
          create_user_with_own_workspace!(
            %{display_name: "You", external_subject: nil},
            "My Debts"
          )

        workspace

      %User{} = user ->
        get_owned_workspace!(user)
    end
  end

  @doc "Fetches a user by id."
  def get_user!(id), do: Repo.get!(User, id)

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

        user
    end
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
  Shares `workspace` with the user matching `email`, granting them member
  access (docs/architecture/0002-auth-and-sharing-model.md: an explicit
  grant, not attribution). Returns `{:error, :user_not_found}` if no user
  with that email has ever logged in.
  """
  def share_workspace_with_email(%Workspace{} = workspace, email) do
    case Repo.get_by(User, email: email) do
      nil ->
        {:error, :user_not_found}

      %User{} = user ->
        %WorkspaceMember{}
        |> WorkspaceMember.changeset(%{
          workspace_id: workspace.id,
          user_id: user.id,
          role: :member
        })
        |> Repo.insert()
    end
  end
end
