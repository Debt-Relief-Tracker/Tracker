defmodule DebtReliefTracker.Settings do
  @moduledoc """
  Per-workspace settings (monthly budget target, currency) and per-person
  retirement/income profiles, plus the global site/mailer identity settings
  edited from `/admin`.
  """

  import Ecto.Query, warn: false

  alias DebtReliefTracker.Repo
  alias DebtReliefTracker.Accounts.{User, Workspace, WorkspaceMember}
  alias DebtReliefTracker.Settings.{Setting, SiteSetting, RetirementProfile}

  @doc "Fetches a workspace's settings, creating a default row if none exists yet."
  def get_settings!(%Workspace{id: workspace_id} = workspace) do
    case Repo.get_by(Setting, workspace_id: workspace_id) do
      nil -> create_default_settings!(workspace)
      %Setting{} = setting -> setting
    end
  end

  defp create_default_settings!(%Workspace{id: workspace_id}) do
    {:ok, setting} =
      %Setting{}
      |> Setting.changeset(%{workspace_id: workspace_id, currency: "USD"})
      |> Repo.insert()

    setting
  end

  def update_settings(%Setting{} = setting, attrs) do
    setting
    |> Setting.changeset(attrs)
    |> Repo.update()
  end

  # --- retirement/income profiles (one per confirmed workspace member, or
  # manual/offline person) ----------------------------------------------------

  @doc "Every retirement/income profile in a workspace, oldest first, preloaded with :user."
  def list_retirement_profiles(%Workspace{id: workspace_id}) do
    from(p in RetirementProfile,
      where: p.workspace_id == ^workspace_id,
      order_by: p.inserted_at,
      preload: :user
    )
    |> Repo.all()
  end

  @doc "Adds a retirement/income profile linked to a confirmed workspace member (owner or `WorkspaceMember`)."
  def add_member_retirement_profile(%Workspace{} = workspace, %User{} = user, attrs) do
    %RetirementProfile{}
    |> RetirementProfile.member_changeset(workspace, user, attrs)
    |> Repo.insert()
  end

  @doc "Adds a retirement/income profile for someone with no account -- a typed name, and an optional email to auto-link later."
  def add_manual_retirement_profile(%Workspace{} = workspace, attrs) do
    %RetirementProfile{}
    |> RetirementProfile.manual_changeset(workspace, attrs)
    |> Repo.insert()
  end

  def update_retirement_profile(%RetirementProfile{} = profile, attrs) do
    profile
    |> RetirementProfile.update_changeset(attrs)
    |> Repo.update()
  end

  def delete_retirement_profile(%RetirementProfile{} = profile) do
    Repo.delete(profile)
  end

  @doc """
  Converts any manual retirement profile awaiting `user`'s email into a
  linked one, now that they have an account -- but only within workspaces
  where they're already a confirmed member (a manual entry only claims once
  its email is *also* a `WorkspaceMember` of that same workspace, not just
  any account with that email anywhere). Called on every OIDC login (see
  `Accounts.get_or_create_user_from_oidc!/1`); a no-op when nothing matches.
  """
  def claim_retirement_profiles(%User{email: nil}), do: :ok

  def claim_retirement_profiles(%User{email: email, id: user_id} = user) do
    from(p in RetirementProfile,
      join: m in WorkspaceMember,
      on: m.workspace_id == p.workspace_id and m.user_id == ^user_id,
      where: p.claim_email == ^email and is_nil(p.user_id)
    )
    |> Repo.all()
    |> Enum.each(fn profile ->
      {:ok, _} = profile |> RetirementProfile.claim_changeset(user) |> Repo.update()
    end)

    :ok
  end

  @doc """
  Downgrades `user`'s retirement profile in `workspace` back to a manual
  entry when their membership is removed, instead of leaving it linked to
  access they no longer have or losing their saved numbers. Re-claims
  automatically (via `claim_retirement_profiles/1`) if they're re-invited
  later. A no-op if they never had a profile.
  """
  def unlink_retirement_profile(%Workspace{id: workspace_id}, %User{} = user) do
    case Repo.get_by(RetirementProfile, workspace_id: workspace_id, user_id: user.id) do
      nil ->
        :ok

      profile ->
        {:ok, _} = profile |> RetirementProfile.unlink_changeset(user) |> Repo.update()
        :ok
    end
  end

  @doc "Fetches the single global site-settings row, creating a default one if none exists yet."
  def get_site_settings do
    case Repo.one(SiteSetting) do
      nil -> create_default_site_settings!()
      %SiteSetting{} = site_settings -> site_settings
    end
  end

  defp create_default_site_settings! do
    {:ok, site_settings} =
      %SiteSetting{}
      |> SiteSetting.changeset(%{site_name: "Debt Relief Tracker"})
      |> Repo.insert()

    site_settings
  end

  def update_site_settings(%SiteSetting{} = site_settings, attrs) do
    site_settings
    |> SiteSetting.changeset(attrs)
    |> Repo.update()
  end
end
