defmodule DebtReliefTracker.Boot do
  @moduledoc """
  One-shot startup tasks run once the supervision tree (and, for releases,
  migrations) is up: ensuring the default no-auth workspace exists and
  seeding its placeholder debts on a truly first run (docs/plan.md Phase 3).

  Idempotent -- safe to run on every application start, not just the first.
  """

  alias DebtReliefTracker.{Accounts, Debts}

  def run do
    # First: refuse to start in an unsafe E2EE configuration (ADR 0007).
    DebtReliefTracker.E2EE.check_boot!()

    workspace = Accounts.ensure_default_workspace!()
    Debts.seed_placeholders_if_empty!(workspace)
    :ok
  end
end
