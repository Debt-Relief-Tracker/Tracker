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

  describe "formula injection guard (text cells only)" do
    test "every trigger char is prefixed with a single quote, identically on both sides" do
      names = [
        "=1+1",
        "+1",
        "-1",
        "@SUM(A1)",
        "\tTab",
        "\rCR",
        "Mid=dle+x-y@z",
        "Ünï=日本",
        "",
        "'=already"
      ]

      expected = [
        "'=1+1",
        "'+1",
        "'-1",
        "'@SUM(A1)",
        "'\tTab",
        "'\rCR",
        "Mid=dle+x-y@z",
        "Ünï=日本",
        "",
        "'=already"
      ]

      server_debts =
        names
        |> Enum.with_index()
        |> Enum.map(fn {n, i} ->
          %DebtReliefTracker.Debts.Debt{
            id: "d#{i}",
            name: n,
            type: :revolving,
            status: :active,
            balance: Decimal.new("-5.00"),
            apr: Decimal.new("-1.50")
          }
        end)

      server = server_debts |> CSVExport.debts_csv() |> IO.iodata_to_binary()

      snapshot = %{
        debts:
          Enum.map(server_debts, fn d ->
            %{
              id: d.id,
              name: d.name,
              type: "revolving",
              status: "active",
              balance: -500,
              apr_bp: -150,
              minimum_payment_floor: nil,
              minimum_payment_rate_bp: nil,
              fixed_payment: nil,
              credit_limit: nil
            }
          end),
        payments: []
      }

      client = CsvExport.debts(snapshot)
      assert client == server

      first_cells =
        server
        |> String.split("\r\n", trim: true)
        |> tl()
        |> Enum.map(fn line -> line |> String.split(",") |> hd() end)

      assert first_cells == Enum.map(expected, &String.trim_leading(&1, "\r"))
      assert server =~ ",-5.00,-1.50,"
      refute server =~ "'-5.00"
    end
  end
end
