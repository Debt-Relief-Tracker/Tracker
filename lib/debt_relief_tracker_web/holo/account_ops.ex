defmodule DebtReliefTrackerWeb.Holo.AccountOps do
  @moduledoc """
  Server-only account/workspace operations behind the Hologram header and
  settings modal commands. Everything takes the already-resolved `user`
  (`nil` in no-auth mode) and `workspace` from `Holo.Context` -- never
  client-supplied ids -- and re-checks authorization itself, exactly like the
  LiveView's `save_settings` / sharing handlers did.

  Account, sharing and preference data is deliberately not part of the
  `Storage` snapshot (it is not E2EE financial data).
  """

  alias DebtReliefTracker.Accounts
  alias DebtReliefTracker.Accounts.{User, Workspace, WorkspaceInvitation, WorkspaceMember}
  alias DebtReliefTracker.Settings
  alias DebtReliefTracker.Storage
  alias DebtReliefTrackerWeb.Holo.Format
  alias DebtReliefTrackerWeb.OIDC

  @themes ~w(system light dark)

  @doc "The user whose profile the UI edits: the signed-in one, or no-auth mode's implicit user."
  def profile_user(nil), do: Accounts.get_default_user!()
  def profile_user(%User{} = user), do: user

  @doc """
  Whether the session may rename the workspace / change its currency / share
  it. In no-auth mode there is one implicit user and workspace, so always.
  """
  def owner?(workspace, user) do
    cond do
      not OIDC.enabled?() -> true
      user == nil -> false
      true -> Accounts.owner?(workspace, user)
    end
  end

  @doc """
  The `:settings` modal map the page keeps in `modal`: everything the
  settings modal needs that is not in the snapshot. `extra` (e.g. `notice`)
  is merged in.
  """
  def settings_modal(user, workspace, extra \\ %{}) do
    owner? = owner?(workspace, user)
    sharing? = owner? and OIDC.enabled?() and user != nil

    Map.merge(
      %{
        type: :settings,
        is_owner: owner?,
        display_name_editability: Accounts.display_name_editability(profile_user(user)),
        accepted_members:
          if(owner?,
            do: for(m <- Accounts.list_workspace_members(workspace), do: member(m)),
            else: []
          ),
        pending_invitations:
          if(sharing?,
            do: for(i <- Accounts.list_pending_invitations(workspace), do: invitation(i)),
            else: []
          ),
        notice: nil,
        error: nil
      },
      extra
    )
  end

  defp member(%WorkspaceMember{} = m), do: %{id: m.id, name: m.user.display_name}
  defp invitation(%WorkspaceInvitation{} = i), do: %{id: i.id, email: i.email}

  @doc """
  The single Save of the settings modal. `params` has string keys
  `"display_name"`, `"workspace_name"`, `"currency"` (client-supplied, so
  each part is only applied if this user may edit it). Every section is
  validated before any is written, so an invalid tracker name can't leave a
  display name already pushed to the IdP.

  Returns `{:ok, snapshot | nil}` (a fresh snapshot only when the currency
  changed) or `{:error, %{display_name: msg, workspace_name: msg, general: msg}}`.
  """
  def save_settings(user, workspace, params) do
    profile = profile_user(user)
    owner? = owner?(workspace, user)
    name_editable? = Accounts.display_name_editability(profile) != :read_only
    display_name = if name_editable?, do: params["display_name"]
    workspace_name = if owner?, do: params["workspace_name"]
    currency = if owner? and params["currency"] in Format.currency_codes(), do: params["currency"]

    user_cs =
      display_name && User.display_name_changeset(profile, %{"display_name" => display_name})

    ws_cs = workspace_name && Workspace.rename_changeset(workspace, %{"name" => workspace_name})

    case validation_errors(user_cs, ws_cs) do
      errors when map_size(errors) > 0 ->
        {:error, errors}

      _ ->
        with :ok <- save_display_name(profile, display_name),
             :ok <- save_workspace_name(workspace, workspace_name) do
          save_currency(workspace, user, currency)
        end
    end
  end

  defp validation_errors(user_cs, ws_cs) do
    %{}
    |> put_error(:display_name, user_cs)
    |> put_error(:workspace_name, ws_cs)
  end

  defp put_error(errors, _key, nil), do: errors
  defp put_error(errors, _key, %{valid?: true}), do: errors

  defp put_error(errors, key, %Ecto.Changeset{} = cs) do
    {_field, {message, _opts}} = hd(cs.errors)
    Map.put(errors, key, message)
  end

  defp save_display_name(_profile, nil), do: :ok

  defp save_display_name(profile, name) do
    case Accounts.update_display_name(profile, %{"display_name" => name}) do
      {:ok, _user} ->
        :ok

      {:error, %Ecto.Changeset{} = cs} ->
        {:error, put_error(%{}, :display_name, cs)}

      {:error, :idp_update_failed} ->
        {:error,
         %{
           general:
             "Couldn't update your sign-in profile, so nothing was saved. Try again shortly."
         }}

      {:error, :read_only} ->
        :ok
    end
  end

  defp save_workspace_name(_workspace, nil), do: :ok

  defp save_workspace_name(workspace, name) do
    case Accounts.update_workspace(workspace, %{"name" => name}) do
      {:ok, _workspace} -> :ok
      {:error, cs} -> {:error, put_error(%{}, :workspace_name, cs)}
    end
  end

  defp save_currency(_workspace, _user, nil), do: {:ok, nil}

  defp save_currency(workspace, user, currency) do
    if Settings.get_settings!(workspace).currency == currency do
      {:ok, nil}
    else
      case Storage.apply_change(workspace, user, {:update_settings, %{currency: currency}}) do
        {:ok, snapshot} -> {:ok, snapshot}
        {:error, _} -> {:error, %{general: "Couldn't save the currency."}}
      end
    end
  end

  @doc "Invite or share by email. `{:ok, message}` / `{:error, message}`."
  def share_workspace(user, workspace, email) do
    email = String.trim(email || "")

    cond do
      DebtReliefTracker.E2EE.enabled?() ->
        {:error, "Sharing is not available with end-to-end encryption."}

      not (OIDC.enabled?() and user != nil and Accounts.owner?(workspace, user)) ->
        {:error, "Only the owner can share this tracker."}

      email == "" ->
        {:error, "Enter an email address."}

      true ->
        case Accounts.share_workspace_with_email(workspace, email, user) do
          {:ok, %WorkspaceMember{}} ->
            {:ok, "Shared with #{email}."}

          {:ok, %WorkspaceInvitation{}} ->
            {:ok, "Invited #{email} -- they'll get access once they sign in."}

          {:error, %Ecto.Changeset{data: %WorkspaceMember{}}} ->
            {:error, "#{email} already has access."}

          {:error, %Ecto.Changeset{data: %WorkspaceInvitation{}}} ->
            {:error, "#{email} has already been invited."}
        end
    end
  end

  @doc "Cancels a pending invitation (owner only; otherwise a no-op)."
  def cancel_invitation(user, workspace, id) do
    if user && Accounts.owner?(workspace, user), do: Accounts.cancel_invitation(workspace, id)
    :ok
  end

  @doc "Removes a member (owner only; otherwise a no-op)."
  def remove_member(user, workspace, id) do
    if user && Accounts.owner?(workspace, user), do: Accounts.remove_member(workspace, id)
    :ok
  end

  @doc "Resets the onboarding tutorial flag for the profile user."
  def restart_tutorial(user) do
    {:ok, _} = Accounts.set_tutorial_seen(profile_user(user), false)
    :ok
  end

  @doc """
  Saves the theme to the account. An unknown theme is just not saved (the
  browser has already applied it locally either way).
  """
  def save_theme(user, theme) when theme in @themes do
    {:ok, _} = Accounts.update_preferences(profile_user(user), %{theme: theme})
    :ok
  end

  def save_theme(_user, _theme), do: :error

  @doc "Display names of everyone with access, by user id, for the activity log."
  def actor_names(workspace) do
    for m <- Accounts.list_confirmed_members(workspace), into: %{} do
      {m.user.id, m.user.display_name}
    end
  end

  @doc """
  Switches to `workspace_id` if the user belongs to it. Returns the id to
  keep in the session, or `nil` if it is not one of theirs.
  """
  def switchable_workspace_id(nil, _workspace_id), do: nil

  def switchable_workspace_id(%User{} = user, workspace_id) do
    Enum.find_value(Accounts.list_workspaces_for_user(user), fn w ->
      if w.id == workspace_id, do: w.id
    end)
  end
end
