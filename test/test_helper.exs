# Real-browser tests (test/support/browser_case.ex) are opt-in:
# `mix test --include browser`. The 500-payment timing test: `E2EE_PERF=1`.
ExUnit.start(exclude: [:browser])
Ecto.Adapters.SQL.Sandbox.mode(DebtReliefTracker.Repo.configured_repo(), :manual)
