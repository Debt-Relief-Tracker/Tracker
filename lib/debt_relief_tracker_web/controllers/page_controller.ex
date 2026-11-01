defmodule DebtReliefTrackerWeb.PageController do
  @moduledoc """
  `/` has no page of its own: the dashboard is the Hologram page at `/app`
  (`DebtReliefTrackerWeb.Holo.DashboardPage`), so `/` redirects there in every
  mode. A 302 (not 301) so browsers never cache the redirect permanently.
  """

  use DebtReliefTrackerWeb, :controller

  def home(conn, _params), do: redirect(conn, to: "/app")
end
