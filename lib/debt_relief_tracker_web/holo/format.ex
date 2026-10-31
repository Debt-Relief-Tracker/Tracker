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

  @doc """
  Cents as plain input text, no symbol or grouping: `123456` -> `"1234.56"`,
  `-5` -> `"-0.05"` (what a `type="number"` money input holds).
  """
  def plain_amount(cents) when is_integer(cents) do
    sign = if cents < 0, do: "-", else: ""
    abs_cents = abs(cents)
    "#{sign}#{div(abs_cents, 100)}.#{pad2(rem(abs_cents, 100))}"
  end

  @doc """
  Parses typed dollars into cents with integer string math (no Decimal or
  float): `"12"` -> `{:ok, 1200}`, `"-3.5"` -> `{:ok, -350}`, `".5"` ->
  `{:ok, 50}`; more than two decimals round half up (`"1.005"` -> `{:ok, 101}`).
  Anything else (empty, letters, grouping commas, `"1.2.3"`) is `:error`.
  """
  def parse_cents(text) when is_binary(text) do
    {sign, unsigned} =
      case String.trim(text) do
        "-" <> rest -> {-1, rest}
        trimmed -> {1, trimmed}
      end

    case String.split(unsigned, ".") do
      [whole] -> unsigned_cents(whole, "")
      [whole, frac] -> unsigned_cents(whole, frac)
      _ -> :error
    end
    |> case do
      {:ok, cents} -> {:ok, sign * cents}
      :error -> :error
    end
  end

  def parse_cents(_not_text), do: :error

  defp unsigned_cents("", ""), do: :error

  defp unsigned_cents(whole, frac) do
    if digits?(whole) and digits?(frac) do
      padded = frac <> "000"
      cents = to_int(whole) * 100 + to_int(String.slice(padded, 0, 2))
      round_up = if to_int(String.slice(padded, 2, 1)) >= 5, do: 1, else: 0
      {:ok, cents + round_up}
    else
      :error
    end
  end

  # Byte-wise (a bitstring generator, which Hologram's client runtime
  # supports) rather than via String.graphemes/1.
  defp digits?(text), do: Enum.all?(for(<<byte <- text>>, do: byte), &(&1 in ?0..?9))

  defp to_int(""), do: 0
  defp to_int(digits), do: String.to_integer(digits)

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
