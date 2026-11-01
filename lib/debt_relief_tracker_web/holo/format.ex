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

  @doc """
  Parses user-typed decimal text into an integer scaled by `10^scale`, with
  integer math only (no Decimal/float/regex): `parse_scaled("12.5", 2)` ->
  `{:ok, 1250}`. Ignores spaces, commas and a leading `$`; rounds half up
  past `scale` digits. Blank -> `{:ok, nil}`; anything else -> `:error`.
  """
  def parse_scaled(text, scale) when is_binary(text) and is_integer(scale) do
    cleaned =
      text
      |> String.replace(" ", "")
      |> String.replace(",", "")
      |> String.replace("$", "")

    case cleaned do
      "" -> {:ok, nil}
      "-" <> rest -> negate(parse_unsigned(rest, scale))
      "+" <> rest -> parse_unsigned(rest, scale)
      _ -> parse_unsigned(cleaned, scale)
    end
  end

  def parse_scaled(_not_text, _scale), do: {:ok, nil}

  @doc "Dollars text -> cents (`parse_scaled(text, 2)`): \"12.34\" -> `{:ok, 1234}`."
  def parse_cents(text), do: parse_scaled(text, 2)

  defp negate({:ok, n}) when is_integer(n), do: {:ok, -n}
  defp negate(other), do: other

  defp parse_unsigned(text, scale) do
    {whole, frac} =
      case String.split(text, ".") do
        [whole] -> {whole, ""}
        [whole, frac] -> {whole, frac}
        _ -> {:error, :error}
      end

    cond do
      whole == :error -> :error
      whole == "" and frac == "" -> :error
      not digits?(whole) or not digits?(frac) -> :error
      true -> {:ok, scale_digits(whole, frac, scale)}
    end
  end

  defp digits?(""), do: true
  defp digits?(text), do: text |> String.to_charlist() |> Enum.all?(&(&1 >= ?0 and &1 <= ?9))

  defp scale_digits(whole, frac, scale) do
    padded = frac <> String.duplicate("0", scale)
    kept = String.slice(padded, 0, scale)
    next_digit = String.slice(frac <> "0", scale, 1)
    base = to_int(whole <> kept)
    if next_digit >= "5", do: base + 1, else: base
  end

  defp to_int(""), do: 0
  defp to_int(digits), do: String.to_integer(digits)

  @doc """
  Inverse of `parse_scaled/2` for input boxes: `to_plain(450_000, 2)` ->
  `"4500.00"`, `to_plain(200, 4, 2)` -> `"0.02"`. Keeps at least
  `min_decimals` decimals (default `scale`), trimming trailing zeros beyond.
  `nil` -> `""`.
  """
  def to_plain(value, scale, min_decimals \\ nil)

  def to_plain(nil, _scale, _min_decimals), do: ""

  def to_plain(value, scale, min_decimals) when is_integer(value) do
    min_decimals = min_decimals || scale
    sign = if value < 0, do: "-", else: ""
    abs_value = abs(value)
    divisor = pow10(scale)
    whole = div(abs_value, divisor)
    frac = abs_value |> rem(divisor) |> Integer.to_string() |> String.pad_leading(scale, "0")
    frac = trim_zeros(frac, min_decimals)
    if frac == "", do: "#{sign}#{whole}", else: "#{sign}#{whole}.#{frac}"
  end

  @doc "Cents -> plain input text (`450_000` -> `\"4500.00\"`), no symbol or grouping."
  def cents_input(cents), do: to_plain(cents, 2)

  defp pow10(0), do: 1
  defp pow10(n), do: 10 * pow10(n - 1)

  defp trim_zeros(frac, min_decimals) do
    if String.length(frac) > min_decimals and String.ends_with?(frac, "0") do
      trim_zeros(String.slice(frac, 0, String.length(frac) - 1), min_decimals)
    else
      frac
    end
  end

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
