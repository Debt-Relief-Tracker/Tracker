import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/debt_relief_tracker start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :debt_relief_tracker, DebtReliefTrackerWeb.Endpoint, server: true
end

# See docs/architecture/0001-dual-database-adapter.md: DATABASE_URL selects
# Postgres; otherwise SQLite is used (the self-hosted default), reading the
# file path from DATABASE_PATH. DebtReliefTracker.Application reads the
# :ecto_adapter value set here to decide which real Ecto.Repo to start.
database_url = System.get_env("DATABASE_URL")

if database_url do
  config :debt_relief_tracker, :ecto_adapter, :postgres

  config :debt_relief_tracker, DebtReliefTracker.Repo.Postgres,
    url: database_url,
    ssl: System.get_env("DATABASE_USE_SSL") || true,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10")
else
  config :debt_relief_tracker, :ecto_adapter, :sqlite

  database_path =
    System.get_env("DATABASE_PATH") ||
      if config_env() == :prod, do: "/data/debt_tracker.db"

  if database_path do
    config :debt_relief_tracker, DebtReliefTracker.Repo.Sqlite, database: database_path
  end
end

# See docs/architecture/0002-auth-and-sharing-model.md: OIDC is entirely
# optional. All three vars must be set together to enable it; otherwise the
# app runs with no login wall (DebtReliefTrackerWeb.OIDC.enabled?/0 is the
# single gate everything else checks).
oidc_issuer = System.get_env("OIDC_ISSUER")
oidc_client_id = System.get_env("OIDC_CLIENT_ID")
oidc_client_secret = System.get_env("OIDC_CLIENT_SECRET")

if oidc_issuer && oidc_client_id && oidc_client_secret do
  config :debt_relief_tracker, :oidc,
    issuer: oidc_issuer,
    client_id: oidc_client_id,
    client_secret: oidc_client_secret
else
  config :debt_relief_tracker, :oidc, nil
end

if config_env() == :prod do
  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"
  port = String.to_integer(System.get_env("PORT") || "4123")

  config :debt_relief_tracker, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :debt_relief_tracker, DebtReliefTrackerWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://hexdocs.pm/bandit/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0},
      port: port
    ],
    secret_key_base: secret_key_base

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :debt_relief_tracker, DebtReliefTrackerWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://hexdocs.pm/plug/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :debt_relief_tracker, DebtReliefTrackerWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.

  # ## Configuring the mailer
  #
  # In production you need to configure the mailer to use a different adapter.
  # Here is an example configuration for Mailgun:
  #
  #     config :debt_relief_tracker, DebtReliefTracker.Mailer,
  #       adapter: Swoosh.Adapters.Mailgun,
  #       api_key: System.get_env("MAILGUN_API_KEY"),
  #       domain: System.get_env("MAILGUN_DOMAIN")
  #
  # Most non-SMTP adapters require an API client. Swoosh supports Req, Hackney,
  # and Finch out-of-the-box. This configuration is typically done at
  # compile-time in your config/prod.exs:
  #
  #     config :swoosh, :api_client, Swoosh.ApiClient.Req
  #
  # See https://hexdocs.pm/swoosh/Swoosh.html#module-installation for details.
end
