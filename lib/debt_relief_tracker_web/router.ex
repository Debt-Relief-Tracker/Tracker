defmodule DebtReliefTrackerWeb.Router do
  use DebtReliefTrackerWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {DebtReliefTrackerWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
    plug OpenApiSpex.Plug.PutApiSpec, module: DebtReliefTrackerWeb.Api.Spec
  end

  pipeline :api_support_emails do
    plug DebtReliefTrackerWeb.Plugs.ApiAuth, scope: "support_emails:write"
  end

  scope "/", DebtReliefTrackerWeb do
    pipe_through :browser

    live_session :default, on_mount: [{DebtReliefTrackerWeb.UserAuth, :mount_current_scope}] do
      live "/", DashboardLive, :index
    end

    live_session :admin, on_mount: [{DebtReliefTrackerWeb.UserAuth, :require_admin_scope}] do
      live "/admin", AdminLive
    end

    # Optional OIDC login (docs/architecture/0002-auth-and-sharing-model.md) --
    # these routes exist unconditionally but no-op back to "/" if OIDC isn't
    # configured (see AuthController).
    get "/auth/login", AuthController, :login
    get "/auth/callback", AuthController, :callback
    post "/auth/logout", AuthController, :logout

    get "/export/debts.csv", ExportController, :debts
    get "/export/payments.csv", ExportController, :payments
  end

  # Admin API (docs/architecture/0006-support-api-and-tokens.md). Tokens are
  # created/revoked from /admin?tab=tokens. No module alias on these scopes
  # -- OpenApiSpex.Plug.* are library plugs, not DebtReliefTrackerWeb modules.
  scope "/" do
    pipe_through :browser

    get "/api/swaggerui", OpenApiSpex.Plug.SwaggerUI, path: "/api/openapi"
  end

  scope "/api" do
    pipe_through :api

    get "/openapi", OpenApiSpex.Plug.RenderSpec, []
  end

  scope "/api", DebtReliefTrackerWeb.Api do
    pipe_through [:api, :api_support_emails]

    post "/support_emails", SupportEmailController, :create
  end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:debt_relief_tracker, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: DebtReliefTrackerWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end
end
