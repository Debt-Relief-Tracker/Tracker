defmodule DebtReliefTracker.CSVExportTest do
  use DebtReliefTracker.DataCase

  alias DebtReliefTracker.{Accounts, CSVExport, Debts, Payments}
  alias NimbleCSV.RFC4180, as: CSV

  setup do
    %{workspace: Accounts.ensure_default_workspace!()}
  end

  describe "debts_csv/1" do
    test "renders a header row plus one row per debt", %{workspace: workspace} do
      {:ok, _debt} =
        Debts.create_debt(workspace, nil, %{
          "name" => "Visa",
          "type" => "revolving",
          "balance" => "1000.00",
          "apr" => "20.00",
          "minimum_payment_floor" => "25.00",
          "minimum_payment_rate" => "0.02",
          "credit_limit" => "2000.00"
        })

      csv = workspace |> Debts.list_debts() |> CSVExport.debts_csv() |> IO.iodata_to_binary()
      [header, row] = CSV.parse_string(csv, skip_headers: false)

      assert header == [
               "Name",
               "Type",
               "Balance",
               "APR",
               "Status",
               "Minimum Payment Floor",
               "Minimum Payment Rate",
               "Fixed Payment",
               "Credit Limit"
             ]

      # Encrypted decimal columns preserve the exact precision entered
      # (opaque ciphertext, no SQLite NUMERIC-affinity coercion), unlike the
      # pre-encryption behavior where SQLite silently normalized a
      # whole-number-valued TEXT like "1000.00" to an INTEGER storage class
      # and lost the trailing zeros on read.
      assert row == [
               "Visa",
               "revolving",
               "1000.00",
               "20.00",
               "active",
               "25.00",
               "0.02",
               "",
               "2000.00"
             ]
    end
  end

  describe "payments_csv/1" do
    test "renders a header row plus one row per payment, escaping commas/quotes in notes", %{
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
          "paid_on" => "2026-07-11",
          "note" => "paid early, see \"budget\" note"
        })

      csv =
        workspace
        |> Payments.list_payments_for_workspace()
        |> CSVExport.payments_csv()
        |> IO.iodata_to_binary()

      [header, row] = CSV.parse_string(csv, skip_headers: false)

      assert header == [
               "Debt",
               "Amount",
               "Principal Portion",
               "Interest Portion",
               "Paid On",
               "Note"
             ]

      # See the comment in the debts_csv/1 test above re: precision
      # preservation with encrypted decimal columns.
      assert row == [
               "Visa",
               "50.00",
               "50.00",
               "",
               "2026-07-11",
               "paid early, see \"budget\" note"
             ]
    end
  end
end
