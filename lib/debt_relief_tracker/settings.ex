defmodule DebtReliefTracker.Settings do
  @moduledoc """
  Per-workspace settings (monthly budget target, currency), plus the global
  site/mailer identity settings edited from `/admin`.
  """

  alias DebtReliefTracker.Repo
  alias DebtReliefTracker.Accounts.Workspace
  alias DebtReliefTracker.Settings.{Setting, SiteSetting}

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

  def update_retirement_profile(%Setting{} = setting, attrs) do
    setting
    |> Setting.retirement_changeset(attrs)
    |> Repo.update()
  end

  @doc "Whether a workspace has completed the retirement onboarding profile."
  def retirement_profile_set?(%Setting{current_age: current_age, retirement_age: retirement_age}) do
    not is_nil(current_age) and not is_nil(retirement_age)
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
