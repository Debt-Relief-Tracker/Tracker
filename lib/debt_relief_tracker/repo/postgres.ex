defmodule DebtReliefTracker.Repo.Postgres do
  @moduledoc false

  use Ecto.Repo,
    otp_app: :debt_relief_tracker,
    adapter: Ecto.Adapters.Postgres
end
