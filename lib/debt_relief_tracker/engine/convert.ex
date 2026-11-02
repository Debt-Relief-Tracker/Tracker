defmodule DebtReliefTracker.Engine.Convert do
  @moduledoc """
  Server-side bridge from the Decimal world (Ecto schemas, `Calculations`,
  `Planning`) to the integer engine's plain maps. Not client-safe -- it uses
  `Decimal` -- so it is never reachable from Hologram pages; the browser
  only ever sees already-converted integers.
  """

  alias DebtReliefTracker.Engine.Days

  @doc "Decimal dollars -> integer cents, rounded half up. `nil` stays `nil`."
  def to_cents(nil), do: nil
  def to_cents(value), do: value |> to_decimal() |> Decimal.mult(100) |> round_int()

  @doc "A percentage (APR 24.99) -> integer basis points of that percent (2499)."
  def percent_to_bp(nil), do: nil
  def percent_to_bp(value), do: value |> to_decimal() |> Decimal.mult(100) |> round_int()

  @doc "A fraction (0.02) -> integer basis points (200)."
  def fraction_to_bp(nil), do: nil
  def fraction_to_bp(value), do: value |> to_decimal() |> Decimal.mult(10_000) |> round_int()

  @doc "Integer cents -> exact Decimal dollars (the inverse of `to_cents/1`)."
  def from_cents(nil), do: nil
  def from_cents(cents) when is_integer(cents), do: decimal_scaled(cents, -2)

  @doc "Basis points of a percent (2499) -> Decimal percent (24.99)."
  def bp_to_percent(nil), do: nil
  def bp_to_percent(bp) when is_integer(bp), do: decimal_scaled(bp, -2)

  @doc "Basis points (200) -> Decimal fraction (0.02)."
  def bp_to_fraction(nil), do: nil
  def bp_to_fraction(bp) when is_integer(bp), do: decimal_scaled(bp, -4)

  defp decimal_scaled(n, exp), do: Decimal.new(if(n < 0, do: -1, else: 1), abs(n), exp)

  @doc "Any debt-like struct/map with Decimal fields -> the engine's integer debt map."
  def debt(debt) do
    %{
      id: debt.id,
      type: debt.type,
      status: Map.get(debt, :status, :active),
      exclude_from_plan: Map.get(debt, :exclude_from_plan, false) || false,
      balance: to_cents(debt.balance),
      apr_bp: percent_to_bp(debt.apr),
      fixed_payment: to_cents(Map.get(debt, :fixed_payment)),
      minimum_payment_floor: to_cents(Map.get(debt, :minimum_payment_floor)),
      minimum_payment_rate_bp: fraction_to_bp(Map.get(debt, :minimum_payment_rate)),
      credit_limit: to_cents(Map.get(debt, :credit_limit)),
      statement_balance: to_cents(Map.get(debt, :statement_balance)),
      statement_days: statement_days(Map.get(debt, :statement_date)),
      due_day: Map.get(debt, :due_day),
      auto_log_mode: Map.get(debt, :auto_log_mode, :off),
      last_due_handled_on: date_tuple(Map.get(debt, :last_due_handled_on))
    }
  end

  defp statement_days(nil), do: nil
  defp statement_days(%Date{} = date), do: Days.to_days(date_tuple(date))

  defp date_tuple(nil), do: nil
  defp date_tuple(%Date{year: y, month: m, day: d}), do: {y, m, d}

  defp to_decimal(%Decimal{} = d), do: d
  defp to_decimal(n) when is_integer(n), do: Decimal.new(n)
  defp to_decimal(n) when is_float(n), do: Decimal.from_float(n)
  defp to_decimal(n) when is_binary(n), do: Decimal.new(n)

  defp round_int(%Decimal{} = d), do: d |> Decimal.round(0, :half_up) |> Decimal.to_integer()
end
