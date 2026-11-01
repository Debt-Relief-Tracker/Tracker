# Boot-path + encrypted round-trip check, run against a throwaway Postgres:
#
#   scripts/pg_test.sh run mix run --no-start scripts/pg_boot_check.exs
#
# (MIX_ENV=test is set by pg_test.sh; the Sandbox pool is swapped for the real
# one here so the supervision tree boots exactly as it would in production.)
# Starts the real supervision tree (Vault, Repo, Migrator, Scheduler,
# Endpoint), runs Boot, then round-trips every Cloak-encrypted record kind.

alias DebtReliefTracker.{Accounts, Boot, Debts, Payments, Repo, Settings}

unless System.get_env("DATABASE_URL"), do: raise("DATABASE_URL must be set")

Application.put_env(:debt_relief_tracker, DebtReliefTracker.Repo.Postgres,
  Application.fetch_env!(:debt_relief_tracker, DebtReliefTracker.Repo.Postgres)
  |> Keyword.put(:pool, DBConnection.ConnectionPool)
)

Application.put_env(:debt_relief_tracker, :run_scheduler, true)
{:ok, _} = Application.ensure_all_started(:debt_relief_tracker)

active = Repo.active_repo()
IO.puts("active repo: #{inspect(active)}")
true = active == DebtReliefTracker.Repo.Postgres

# Boot twice: must be idempotent.
:ok = Boot.run()
:ok = Boot.run()
workspace = Accounts.ensure_default_workspace!()
debts = Debts.list_debts(workspace)
IO.puts("workspace #{workspace.id}, #{length(debts)} placeholder debts after Boot")
true = debts != []

# Scheduler sweep against Postgres.
:ok = DebtReliefTracker.DuePayments.Scheduler.run_due_checks()
IO.puts("scheduler sweep ok")

# Debt round-trip.
{:ok, debt} =
  Debts.create_debt(workspace, nil, %{
    "name" => "PG Roundtrip Card",
    "type" => "revolving",
    "balance" => "12345.67",
    "apr" => "19.99",
    "minimum_payment_floor" => "25.00",
    "minimum_payment_rate" => "0.02"
  })

loaded = Repo.get!(DebtReliefTracker.Debts.Debt, debt.id)
true = loaded.name == "PG Roundtrip Card"
true = Decimal.equal?(loaded.balance, Decimal.new("12345.67"))
true = Decimal.equal?(loaded.apr, Decimal.new("19.99"))
IO.puts("debt round-trip ok")

# Payment round-trip.
{:ok, _} = Payments.log_payment(workspace, nil, loaded, %{"amount" => "100.00", "note" => "pg", "paid_on" => Date.utc_today()})
[payment | _] = Payments.list_payments_for_debt(loaded)
true = Decimal.equal?(payment.amount, Decimal.new("100.00"))
true = payment.note == "pg"
IO.puts("payment round-trip ok")

# Settings round-trip.
setting = Settings.get_settings!(workspace)
{:ok, _} = Settings.update_settings(setting, %{"monthly_budget" => "1500.50"})
true = Decimal.equal?(Settings.get_settings!(workspace).monthly_budget, Decimal.new("1500.50"))
IO.puts("settings round-trip ok")

# Retirement profile round-trip.
{:ok, profile} =
  Settings.add_manual_retirement_profile(workspace, %{
    "name" => "PG Person",
    "current_age" => "40",
    "retirement_age" => "65",
    "current_retirement_savings" => "50000.00",
    "monthly_retirement_contribution" => "500.00",
    "monthly_gross_income" => "6000.00",
    "post_debt_investment_pct" => "50",
    "expected_annual_return_pct" => "6.5"
  })

reloaded = Repo.get!(DebtReliefTracker.Settings.RetirementProfile, profile.id)
true = reloaded.name == "PG Person"
true = reloaded.current_age == 40
true = Decimal.equal?(reloaded.current_retirement_savings, Decimal.new("50000.00"))
IO.puts("retirement profile round-trip ok")

# Cleanup of what this script created is unnecessary: the cluster is throwaway.
IO.puts("PG BOOT CHECK PASSED")
