defmodule DebtReliefTracker.Boot do
  @moduledoc """
  One-shot startup tasks run once the supervision tree (and, for releases,
  migrations) is up: ensuring the default no-auth workspace exists and
  seeding its placeholder debts on a truly first run (docs/plan.md Phase 3).

  Idempotent -- safe to run on every application start, not just the first.
  """

  alias DebtReliefTracker.{Accounts, Debts}

  def run do
    workspace = Accounts.ensure_default_workspace!()
    Debts.seed_placeholders_if_empty!(workspace)
    :ok
  end
end
