defmodule DebtReliefTracker.Settings do
  @moduledoc "Per-workspace settings (monthly budget target, currency)."

  alias DebtReliefTracker.Repo
  alias DebtReliefTracker.Accounts.Workspace
  alias DebtReliefTracker.Settings.Setting

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
end
