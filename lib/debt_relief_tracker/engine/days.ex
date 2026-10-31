defmodule DebtReliefTracker.Engine.Days do
  @moduledoc """
  Calendar math on plain integers, for the client-safe engine. A date is a
  `{year, month, day}` tuple; `to_days/1` maps it to a day count (days since
  1970-01-01, proleptic Gregorian) so two dates subtract and compare as
  integers. Hologram has no `Date`/`:calendar` port, so this stands in for
  `Date.diff/2`, `Date.compare/2` and `Date.days_in_month/1`.
  """

  def to_days({year, month, day}) do
    y = if month <= 2, do: year - 1, else: year
    era = div(y, 400)
    yoe = y - era * 400
    mp = rem(month + 9, 12)
    doy = div(153 * mp + 2, 5) + day - 1
    doe = yoe * 365 + div(yoe, 4) - div(yoe, 100) + doy
    era * 146_097 + doe - 719_468
  end

  def leap_year?(year), do: rem(year, 4) == 0 and (rem(year, 100) != 0 or rem(year, 400) == 0)

  def days_in_month(year, 2), do: if(leap_year?(year), do: 29, else: 28)
  def days_in_month(_year, month) when month in [4, 6, 9, 11], do: 30
  def days_in_month(_year, _month), do: 31

  @doc "The given day clamped to the month's real last day (31 in February -> 28/29)."
  def clamped({year, month, day}), do: {year, month, min(day, days_in_month(year, month))}

  def previous_month(year, 1), do: {year - 1, 12}
  def previous_month(year, month), do: {year, month - 1}
end
