defmodule DebtReliefTracker.Accounts.UserPreferences do
  @moduledoc """
  Per-user UI preferences, embedded in `users.preferences` (a single map
  column) so adding one is a new field here rather than a migration. Keys
  missing from the stored map fall back to these defaults.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  embedded_schema do
    # Set only when the user explicitly clicks the theme toggle -- see
    # DebtReliefTrackerWeb.UserAuth's :theme_preference hook.
    field :theme, Ecto.Enum, values: [:system, :light, :dark], default: :system
  end

  def changeset(preferences, attrs) do
    preferences
    |> cast(attrs, [:theme])
    |> validate_required([:theme])
  end
end
