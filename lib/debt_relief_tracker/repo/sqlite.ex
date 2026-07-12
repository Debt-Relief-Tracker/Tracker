defmodule DebtReliefTracker.Repo.Sqlite do
  @moduledoc false

  use Ecto.Repo,
    otp_app: :debt_relief_tracker,
    adapter: Ecto.Adapters.SQLite3
end
