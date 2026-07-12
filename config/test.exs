import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :debt_relief_tracker, DebtReliefTracker.Repo.Sqlite,
  database: Path.expand("../data/debt_relief_tracker_test.db", __DIR__),
  pool_size: 5,
  pool: Ecto.Adapters.SQL.Sandbox

# DebtReliefTracker.Boot writes to the database at application start, which
# would fail under the Sandbox's :manual mode before any test has checked out
# a connection -- tests seed their own fixtures instead.
config :debt_relief_tracker, :run_boot_tasks, false

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :debt_relief_tracker, DebtReliefTrackerWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "HGSZ25JeWJcHnUHU4mFtI2xnbyu9SHc1xq35zkF38ASVoT3SduyG8LKlVGGtghcu",
  server: false

# In test we don't send emails
config :debt_relief_tracker, DebtReliefTracker.Mailer, adapter: Swoosh.Adapters.Test

# Disable swoosh api client as it is only required for production adapters
config :swoosh, :api_client, false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true
