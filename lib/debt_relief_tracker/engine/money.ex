defmodule DebtReliefTracker.Engine.Money do
  @moduledoc """
  Integer-only money helpers for the client-safe payoff engine
  (docs/architecture/0007-e2ee.md). Amounts are integer cents, rates are
  integer basis points (APR 24.99% -> `2499`; a 2% minimum-payment rate ->
  `200`). No `Decimal`, no floats, no `Date` -- Hologram has no port of any
  of them, and integers behave identically on the BEAM and in the browser.
  """

  @doc "`n / d` rounded half up. `n` and `d` must be non-negative / positive."
  def div_round(n, d) when n >= 0 and d > 0, do: div(2 * n + d, 2 * d)

  @doc "`a * b / d` rounded half up."
  def mul_div(a, b, d), do: div_round(a * b, d)

  def clamp_non_negative(n) when n < 0, do: 0
  def clamp_non_negative(n), do: n
end
