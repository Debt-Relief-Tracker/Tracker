defmodule DebtReliefTrackerWeb.Holo.CsvExport do
  @moduledoc """
  Client-safe CSV export from a `Storage` snapshot: the E2EE-mode counterpart of
  the server's `DebtReliefTracker.CSVExport` (which cannot run there: the
  server cannot read the data and `/export/*.csv` answers 410). Runs in the
  browser; `Holo.CsvDownload` hands the text to the browser as a file.

  Produces the same bytes as the server module for the same data
  (`test/debt_relief_tracker_web/holo/csv_export_test.exs`): same header, same
  columns and order, RFC 4180 quoting exactly like `NimbleCSV.RFC4180` (a
  field is quoted when it contains a comma, a double quote or a line feed;
  quotes are doubled; rows end in CRLF), and the same formula-injection guard:
  a TEXT cell (name, note) starting with `=`, `+`, `-`, `@`, TAB or CR gets a
  single quote prefix (`=SUM(A1)` -> `'=SUM(A1)`); numeric/date columns are
  never touched (a negative amount stays `-5.00`). Money columns have two decimals, APR two, and the minimum payment
  rate four (what the exact `Decimal` columns hold); the server prints the
  decimals as stored, so a value saved as `20` rather than `20.00` can differ
  there.
  """

  alias DebtReliefTrackerWeb.Holo.Format

  @debts_header [
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
  @payments_header ["Debt", "Amount", "Principal Portion", "Interest Portion", "Paid On", "Note"]

  @doc "All debts of the snapshot as CSV text (header + one row per debt, CRLF line ends)."
  def debts(snapshot) do
    rows =
      for debt <- snapshot.debts do
        [
          text(debt.name),
          debt.type,
          Format.to_plain(debt.balance, 2),
          Format.to_plain(debt.apr_bp, 2),
          debt.status,
          Format.to_plain(debt.minimum_payment_floor, 2),
          Format.to_plain(debt.minimum_payment_rate_bp, 4),
          Format.to_plain(debt.fixed_payment, 2),
          Format.to_plain(debt.credit_limit, 2)
        ]
      end

    dump([@debts_header | rows])
  end

  @doc "All payments of the snapshot (newest first, as the server lists them) as CSV text."
  def payments(snapshot) do
    names = Map.new(snapshot.debts, fn debt -> {debt.id, debt.name} end)

    rows =
      for payment <- snapshot.payments do
        [
          text(Map.get(names, payment.debt_id, "")),
          Format.to_plain(payment.amount, 2),
          Format.to_plain(payment.principal_portion, 2),
          Format.to_plain(payment.interest_portion, 2),
          payment.paid_on || "",
          text(payment.note)
        ]
      end

    dump([@payments_header | rows])
  end

  @doc "Rows (lists of strings) -> CSV text, quoted like `NimbleCSV.RFC4180.dump_to_iodata/1`."
  def dump(rows) do
    Enum.map_join(rows, fn row -> Enum.map_join(row, ",", &field/1) <> "\r\n" end)
  end

  # Spreadsheet formula-injection guard for TEXT cells (names, notes): a leading
  # `=`, `+`, `-`, `@`, TAB or CR gets a single quote prefix so Excel/Sheets
  # treat it as text. IDENTICAL in `DebtReliefTrackerWeb.Holo.CsvExport`
  # (byte parity is tested). Numeric/date columns are never touched.
  defp text(nil), do: ""

  defp text(value) do
    if String.starts_with?(value, ["=", "+", "-", "@", "\t", "\r"]),
      do: "'" <> value,
      else: value
  end

  defp field(value) do
    text = value || ""

    if String.contains?(text, ["\"", ",", "\r\n", "\n"]) do
      "\"" <> String.replace(text, "\"", "\"\"") <> "\""
    else
      text
    end
  end
end
