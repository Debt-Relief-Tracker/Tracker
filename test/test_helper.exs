# Real-browser tests (test/support/browser_case.ex) are opt-in:
# `mix test --include browser`.
ExUnit.start(exclude: [:browser])
Ecto.Adapters.SQL.Sandbox.mode(DebtReliefTracker.Repo.configured_repo(), :manual)
