defmodule DebtReliefTrackerWeb.Holo.CsvExportTest do
  @moduledoc """
  Parity of the browser-side CSV (`Holo.CsvExport`, E2EE mode) with the
  server's `DebtReliefTracker.CSVExport`: the same workspace data must give
  byte-identical text, including awkward strings.
  """
  use DebtReliefTracker.DataCase, async: true

  alias DebtReliefTracker.{Accounts, CSVExport, Debts, Payments, Storage}
  alias DebtReliefTrackerWeb.Holo.CsvExport

  @tricky [
    "Plain",
    "With, comma",
    ~S|With "quotes"|,
    "Two\nlines",
    "Windows\r\nlines",
    "Lone\rcarriage",
    "=SUM(A1:A9)",
    "+1+1",
    "-2+3",
    "@cmd",
    "\tTabbed",
    "Ünïcödé 日本語 🙂",
    " leading and trailing ",
    ~S|"|,
    ","
  ]

  setup do
    workspace = Accounts.ensure_default_workspace!()

    debts =
      for {name, i} <- Enum.with_index(@tricky) do
        {:ok, debt} =
          Debts.create_debt(workspace, nil, %{
            "name" => name,
            "type" => if(rem(i, 2) == 0, do: "revolving", else: "installment"),
            "balance" => "#{1000 + i}.50",
            "apr" => "19.99",
            "minimum_payment_floor" => "35.00",
            "minimum_payment_rate" => "0.0200",
            "fixed_payment" => "250.00",
            "credit_limit" => "5000.00"
          })

        debt
      end

    for {debt, i} <- Enum.with_index(debts) do
      {:ok, _} =
        Payments.log_payment(workspace, nil, debt, %{
          "amount" => "10.0#{rem(i, 10)}",
          "paid_on" => "2026-0#{rem(i, 9) + 1}-1#{rem(i, 9)}",
          "note" => Enum.at(@tricky, rem(i + 3, length(@tricky)))
        })
    end

    # a payment without a note, a paid-off debt
    {:ok, _} =
      Payments.log_payment(workspace, nil, hd(debts), %{
        "amount" => "1.00",
        "paid_on" => "2026-05-05"
      })

    {:ok, _} = Debts.mark_paid_off(workspace, nil, Enum.at(debts, 2))
    {:ok, snapshot} = Storage.load(workspace)
    {:ok, workspace: workspace, snapshot: snapshot}
  end

  test "debts: byte-identical to the server module", %{workspace: ws, snapshot: snapshot} do
    server = ws |> Debts.list_debts() |> CSVExport.debts_csv() |> IO.iodata_to_binary()
    client = CsvExport.debts(snapshot)
    assert client == server
    assert String.starts_with?(client, "Name,Type,Balance,APR,Status,")
  end

  test "payments: byte-identical to the server module", %{workspace: ws, snapshot: snapshot} do
    server =
      ws
      |> Payments.list_payments_for_workspace()
      |> CSVExport.payments_csv()
      |> IO.iodata_to_binary()

    assert CsvExport.payments(snapshot) == server
  end

  test "an empty workspace is just the header" do
    snapshot = %{debts: [], payments: []}
    assert CsvExport.debts(snapshot) == IO.iodata_to_binary(CSVExport.debts_csv([]))
    assert CsvExport.payments(snapshot) == IO.iodata_to_binary(CSVExport.payments_csv([]))
  end
end
