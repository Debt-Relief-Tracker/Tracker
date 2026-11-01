defmodule DebtReliefTrackerWeb.Holo.Format do
  @moduledoc """
  Display formatting for the Hologram UI, over integer cents / basis points.
  Client-safe (no Decimal, no regex). Mirrors `DashboardLive.format_money/2`
  and `format_percent/1` so both UIs print the same strings.
  """

  def symbol("EUR"), do: "€"
  def symbol("GBP"), do: "£"
  def symbol("JPY"), do: "¥"
  def symbol(_usd_cad_aud_or_unknown), do: "$"

  @doc "Currency codes the settings can choose from."
  def currency_codes, do: ["AUD", "CAD", "EUR", "GBP", "JPY", "USD"]

  @doc "12345 cents, \"USD\" -> \"$123.45\"; negatives get a leading \"-\"."
  def money(cents, currency) when is_integer(cents) do
    sign = if cents < 0, do: "-", else: ""
    abs_cents = abs(cents)
    whole = div(abs_cents, 100)
    frac = rem(abs_cents, 100)
    "#{sign}#{symbol(currency)}#{group_thousands(Integer.to_string(whole))}.#{pad2(frac)}"
  end

  def money(_nil, currency), do: "#{symbol(currency)}0.00"

  @doc "Basis points of a fraction (5000) -> \"50%\"; `nil` -> \"0%\"."
  def percent_bp(bp) when is_integer(bp), do: "#{Integer.to_string(div(bp + 50, 100))}%"
  def percent_bp(_nil), do: "0%"

  defp pad2(n) when n < 10, do: "0#{n}"
  defp pad2(n), do: Integer.to_string(n)

  defp group_thousands(digits) do
    len = String.length(digits)

    if len <= 3 do
      digits
    else
      head = String.slice(digits, 0, len - 3)
      tail = String.slice(digits, len - 3, 3)
      group_thousands(head) <> "," <> tail
    end
  end
end
