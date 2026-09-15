defmodule DebtReliefTracker.CSVExport do
  @moduledoc """
  Renders debts/payments as CSV for download (`DebtReliefTrackerWeb.ExportController`).
  Two separate exports rather than one combined file -- a `Debt` row and a
  `Payment` row have different shapes, and both `Debts.list_debts/1` and
  `Payments.list_payments_for_workspace/1` already return exactly the data
  needed with no reshaping.
  """

  alias NimbleCSV.RFC4180, as: CSV

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

  @doc "Renders a workspace's debts as CSV iodata, one row per debt."
  def debts_csv(debts) do
    rows = Enum.map(debts, &debt_row/1)
    CSV.dump_to_iodata([@debts_header | rows])
  end

  @doc "Renders a workspace's payments as CSV iodata, one row per payment. Each `payment.debt` must be preloaded."
  def payments_csv(payments) do
    rows = Enum.map(payments, &payment_row/1)
    CSV.dump_to_iodata([@payments_header | rows])
  end

  defp debt_row(debt) do
    [
      debt.name,
      to_string(debt.type),
      dec(debt.balance),
      dec(debt.apr),
      to_string(debt.status),
      dec(debt.minimum_payment_floor),
      dec(debt.minimum_payment_rate),
      dec(debt.fixed_payment),
      dec(debt.credit_limit)
    ]
  end

  defp payment_row(payment) do
    [
      payment.debt.name,
      dec(payment.amount),
      dec(payment.principal_portion),
      dec(payment.interest_portion),
      date(payment.paid_on),
      payment.note
    ]
  end

  defp dec(nil), do: ""
  defp dec(%Decimal{} = d), do: Decimal.to_string(d)

  defp date(nil), do: ""
  defp date(%Date{} = d), do: Date.to_iso8601(d)
end
