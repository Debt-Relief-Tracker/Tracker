defmodule DebtReliefTrackerWeb.ExportController do
  @moduledoc """
  CSV downloads for a workspace's debts/payments. A LiveView process can't
  force a browser file download by itself, so this is a plain controller
  route the dashboard links to (a real browser navigation, not a
  `phx-click`) rather than a LiveView event.
  """

  use DebtReliefTrackerWeb, :controller

  alias DebtReliefTracker.{Accounts, CSVExport, Debts, Payments}
  alias DebtReliefTrackerWeb.OIDC

  def debts(conn, _params) do
    with {:ok, workspace} <- resolve_workspace(conn) do
      csv = workspace |> Debts.list_debts() |> CSVExport.debts_csv()
      send_download(conn, {:binary, IO.iodata_to_binary(csv)}, filename: "debts.csv")
    else
      :unauthenticated -> redirect(conn, to: ~p"/auth/login")
    end
  end

  def payments(conn, _params) do
    with {:ok, workspace} <- resolve_workspace(conn) do
      csv = workspace |> Payments.list_payments_for_workspace() |> CSVExport.payments_csv()
      send_download(conn, {:binary, IO.iodata_to_binary(csv)}, filename: "payments.csv")
    else
      :unauthenticated -> redirect(conn, to: ~p"/auth/login")
    end
  end

  # Mirrors DashboardLive.mount/3's current_user/current_workspace
  # resolution -- a plain controller route has no LiveView session assigns
  # to reuse directly. Kept here (rather than moved into Accounts) since it
  # depends on DebtReliefTrackerWeb.OIDC, a web-layer concern the Accounts
  # context shouldn't need to know about.
  defp resolve_workspace(conn) do
    if OIDC.enabled?() do
      with user_id when not is_nil(user_id) <- get_session(conn, :user_id),
           {:ok, uuid} <- Ecto.UUID.cast(user_id) do
        {:ok, uuid |> Accounts.get_user!() |> Accounts.current_workspace_for_user()}
      else
        _ -> :unauthenticated
      end
    else
      {:ok, Accounts.ensure_default_workspace!()}
    end
  end
end
