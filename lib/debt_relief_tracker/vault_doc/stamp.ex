defmodule DebtReliefTracker.VaultDoc.Stamp do
  @moduledoc """
  Timestamps and ISO dates for the vault document, on plain strings and
  integers (client-safe: no `DateTime`, `Date` or `Regex`).

  A *stamp* is the canonical UTC form `YYYY-MM-DDTHH:MM:SS.ffffffZ` (always
  six fraction digits, year >= 1970). Fixed width makes plain string
  comparison the same as chronological comparison, which is what the
  last-writer-wins merge relies on. `normalize/1` accepts the looser forms
  the rest of the app produces (`2026-11-01T12:00:00Z`, an optional fraction
  of any length, a missing `Z` as on naive timestamps) and rewrites them to
  the canonical form.

  `bump/1` adds one microsecond; `after_/2` returns the later of a stamp and
  `bump(prev)`, so successive edits of one record always get strictly
  increasing stamps even when the clock does not advance.
  """

  alias DebtReliefTracker.Engine.Days

  @epoch "1970-01-01T00:00:00.000000Z"

  def epoch, do: @epoch

  @doc "Canonical stamp for `str`, or `:error`."
  def normalize(str) when is_binary(str) do
    case parse(str) do
      {:ok, {days, secs, micros}} -> {:ok, format(days, secs, micros)}
      :error -> :error
    end
  end

  def normalize(_), do: :error

  @doc "`normalize/1` or the epoch when `str` is not a timestamp."
  def normalize_or_epoch(str) do
    case normalize(str) do
      {:ok, stamp} -> stamp
      :error -> @epoch
    end
  end

  @doc "True for a canonical stamp."
  def valid?(str) do
    case normalize(str) do
      {:ok, ^str} -> true
      _ -> false
    end
  end

  @doc "One microsecond later."
  def bump(stamp) do
    {:ok, {days, secs, micros}} = parse(stamp)

    if micros < 999_999 do
      format(days, secs, micros + 1)
    else
      total = days * 86_400 + secs + 1
      format(div(total, 86_400), rem(total, 86_400), 0)
    end
  end

  @doc "`stamp` if it is later than `prev`, else `bump(prev)`."
  def after_(stamp, nil), do: stamp
  def after_(stamp, prev), do: if(stamp > prev, do: stamp, else: bump(prev))

  @doc "The later of two stamps (nil-safe)."
  def max_stamp(nil, b), do: b
  def max_stamp(a, nil), do: a
  def max_stamp(a, b), do: if(a >= b, do: a, else: b)

  @doc "`2026-11-01T12:00:00.123456Z` -> `2026-11-01T12:00:00Z` (whole seconds, as `paid_off_at`)."
  def seconds(stamp), do: String.slice(stamp, 0, 19) <> "Z"

  # --- ISO dates -----------------------------------------------------------

  @doc "`\"2026-11-01\"` -> `{:ok, {2026, 11, 1}}` (strict `YYYY-MM-DD`), else `:error`."
  def parse_date(str) when is_binary(str) do
    with [y, m, d] <- String.split(str, "-"),
         true <- String.length(y) == 4 and String.length(m) == 2 and String.length(d) == 2,
         true <- digits?(y) and digits?(m) and digits?(d),
         year = String.to_integer(y),
         month = String.to_integer(m),
         day = String.to_integer(d),
         true <- year >= 1 and month >= 1 and month <= 12,
         true <- day >= 1 and day <= Days.days_in_month(year, month) do
      {:ok, {year, month, day}}
    else
      _ -> :error
    end
  end

  def parse_date(_), do: :error

  def format_date({y, m, d}), do: pad(y, 4) <> "-" <> pad(m, 2) <> "-" <> pad(d, 2)

  @doc "Strict digits-only check (an empty string is not digits)."
  def digits?(""), do: false
  def digits?(str), do: Enum.all?(String.codepoints(str), &(&1 >= "0" and &1 <= "9"))

  # --- internals -----------------------------------------------------------

  # -> {:ok, {epoch_days, second_of_day, micros}} | :error
  defp parse(str) do
    str = if String.ends_with?(str, "Z"), do: String.slice(str, 0, String.length(str) - 1), else: str

    with [date, time] <- String.split(str, "T"),
         {:ok, {y, _, _} = ymd} <- parse_date(date),
         true <- y >= 1970,
         {:ok, {h, mi, s, micros}} <- parse_time(time) do
      {:ok, {Days.to_days(ymd), h * 3600 + mi * 60 + s, micros}}
    else
      _ -> :error
    end
  end

  defp parse_time(time) do
    {whole, frac} =
      case String.split(time, ".") do
        [whole] -> {whole, ""}
        [whole, frac] -> {whole, frac}
        _ -> {"", "bad"}
      end

    with [h, m, s] <- String.split(whole, ":"),
         true <- String.length(h) == 2 and String.length(m) == 2 and String.length(s) == 2,
         true <- digits?(h) and digits?(m) and digits?(s),
         true <- frac == "" or (digits?(frac) and String.length(frac) <= 12),
         hh = String.to_integer(h),
         mm = String.to_integer(m),
         ss = String.to_integer(s),
         true <- hh <= 23 and mm <= 59 and ss <= 59 do
      micros =
        if frac == "",
          do: 0,
          else: frac |> String.pad_trailing(6, "0") |> String.slice(0, 6) |> String.to_integer()

      {:ok, {hh, mm, ss, micros}}
    else
      _ -> :error
    end
  end

  defp format(days, secs, micros) do
    {y, m, d} = civil_from_days(days)

    pad(y, 4) <>
      "-" <>
      pad(m, 2) <>
      "-" <>
      pad(d, 2) <>
      "T" <>
      pad(div(secs, 3600), 2) <>
      ":" <>
      pad(div(rem(secs, 3600), 60), 2) <>
      ":" <>
      pad(rem(secs, 60), 2) <> "." <> pad(micros, 6) <> "Z"
  end

  # Inverse of Days.to_days/1 (Howard Hinnant's civil_from_days), days >= 0.
  defp civil_from_days(days) do
    z = days + 719_468
    era = div(z, 146_097)
    doe = z - era * 146_097
    yoe = div(doe - div(doe, 1460) + div(doe, 36_524) - div(doe, 146_096), 365)
    y = yoe + era * 400
    doy = doe - (365 * yoe + div(yoe, 4) - div(yoe, 100))
    mp = div(5 * doy + 2, 153)
    d = doy - div(153 * mp + 2, 5) + 1
    m = if mp < 10, do: mp + 3, else: mp - 9
    {if(m <= 2, do: y + 1, else: y), m, d}
  end

  defp pad(n, width), do: n |> Integer.to_string() |> String.pad_leading(width, "0")
end
