# Real-browser tests (test/support/browser_case.ex) are opt-in:
# `mix test --include browser`. Slow measurements: `--include perf`.
ExUnit.start(exclude: [:browser, :perf])
Ecto.Adapters.SQL.Sandbox.mode(DebtReliefTracker.Repo.configured_repo(), :manual)
