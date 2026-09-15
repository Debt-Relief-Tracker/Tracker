defmodule DebtReliefTrackerWeb.ExportControllerTest do
  use DebtReliefTrackerWeb.ConnCase

  alias DebtReliefTracker.{Accounts, Debts, Payments}

  setup do
    %{workspace: Accounts.ensure_default_workspace!()}
  end

  describe "GET /export/debts.csv" do
    test "returns a CSV attachment with the workspace's debts", %{
      conn: conn,
      workspace: workspace
    } do
      {:ok, _debt} =
        Debts.create_debt(workspace, nil, %{
          "name" => "Visa",
          "type" => "revolving",
          "balance" => "1000.00",
          "apr" => "20.00",
          "minimum_payment_floor" => "25.00",
          "minimum_payment_rate" => "0.02"
        })

      conn = get(conn, ~p"/export/debts.csv")

      assert conn.status == 200
      assert [disposition] = get_resp_header(conn, "content-disposition")
      assert disposition =~ "debts.csv"
      assert conn.resp_body =~ "Name,Type,Balance"
      assert conn.resp_body =~ "Visa"
    end

    test "doesn't include another workspace's debts", %{conn: conn, workspace: workspace} do
      other_user =
        Accounts.get_or_create_user_from_oidc!(%{
          "sub" => "other",
          "email" => "other@example.com"
        })

      other_workspace = Accounts.current_workspace_for_user(other_user)

      {:ok, _debt} =
        Debts.create_debt(other_workspace, nil, %{
          "name" => "Someone Else's Card",
          "type" => "revolving",
          "balance" => "1.00",
          "apr" => "1.00",
          "minimum_payment_floor" => "1.00",
          "minimum_payment_rate" => "0.01"
        })

      {:ok, _debt} =
        Debts.create_debt(workspace, nil, %{
          "name" => "My Card",
          "type" => "revolving",
          "balance" => "1.00",
          "apr" => "1.00",
          "minimum_payment_floor" => "1.00",
          "minimum_payment_rate" => "0.01"
        })

      conn = get(conn, ~p"/export/debts.csv")

      assert conn.resp_body =~ "My Card"
      refute conn.resp_body =~ "Someone Else's Card"
    end
  end

  describe "GET /export/payments.csv" do
    test "returns a CSV attachment with the workspace's payments", %{
      conn: conn,
      workspace: workspace
    } do
      {:ok, debt} =
        Debts.create_debt(workspace, nil, %{
          "name" => "Visa",
          "type" => "revolving",
          "balance" => "1000.00",
          "apr" => "20.00",
          "minimum_payment_floor" => "25.00",
          "minimum_payment_rate" => "0.02"
        })

      {:ok, _} =
        Payments.log_payment(workspace, nil, debt, %{
          "amount" => "50.00",
          "paid_on" => "2026-07-11"
        })

      conn = get(conn, ~p"/export/payments.csv")

      assert conn.status == 200
      assert [disposition] = get_resp_header(conn, "content-disposition")
      assert disposition =~ "payments.csv"
      assert conn.resp_body =~ "Debt,Amount"
      assert conn.resp_body =~ "Visa"
      assert conn.resp_body =~ "50"
    end
  end
end
