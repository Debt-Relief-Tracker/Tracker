defmodule DebtReliefTracker.VaultClient.Strength do
  @moduledoc """
  A deliberately simple, client-safe passphrase strength estimate for the
  setup wizard (no external library, no floats, no `Regex`). It is advisory --
  the only hard rules are `min_length/0` characters and not being trivially
  guessable (`level 0`).

  Estimate: tenths of a bit = effective length x log2(character pool), where
  the pool is the sum of the character classes used (lowercase 26, uppercase
  26, digits 10, other 33) and repeated characters count half. A short list of
  very common passwords is level 0. Anyone holding the database can try
  passphrases offline, so this is a guide to "long and unusual", not a promise.
  """

  @min_length 12
  @common ~w(password passphrase letmein qwerty qwertyuiop iloveyou admin welcome
             changeme trustno1 123456789012 abcdefghijkl 111111111111 000000000000)

  def min_length, do: @min_length

  @doc """
  `%{length, bits, level (0..4), label, long_enough?, acceptable?}` for a
  passphrase. `acceptable?` = long enough and not level 0.
  """
  def estimate(passphrase) when is_binary(passphrase) do
    chars = String.to_charlist(passphrase)
    length = length(chars)
    unique = chars |> Enum.uniq() |> length()
    pool = pool_size(chars)
    effective_tenths = unique * 10 + div((length - unique) * 10, 4)
    bits10 = div(effective_tenths * bits10_of_pool(pool), 10)
    bits = div(bits10, 10)
    long_enough? = length >= @min_length

    level =
      cond do
        length == 0 -> 0
        common?(passphrase) -> 0
        bits < 28 -> 0
        bits < 40 -> 1
        bits < 60 -> 2
        bits < 80 -> 3
        true -> 4
      end

    %{
      length: length,
      bits: bits,
      level: level,
      label: label(level, length),
      long_enough?: long_enough?,
      acceptable?: long_enough? and level > 0
    }
  end

  defp label(_level, 0), do: "Enter a passphrase"
  defp label(0, _), do: "Too guessable"
  defp label(1, _), do: "Weak"
  defp label(2, _), do: "Fair"
  defp label(3, _), do: "Good"
  defp label(4, _), do: "Strong"

  defp common?(passphrase), do: String.downcase(passphrase) in @common

  defp pool_size(chars) do
    lower = if Enum.any?(chars, &(&1 >= ?a and &1 <= ?z)), do: 26, else: 0
    upper = if Enum.any?(chars, &(&1 >= ?A and &1 <= ?Z)), do: 26, else: 0
    digit = if Enum.any?(chars, &(&1 >= ?0 and &1 <= ?9)), do: 10, else: 0
    other = if Enum.any?(chars, &(not alnum?(&1))), do: 33, else: 0
    lower + upper + digit + other
  end

  defp alnum?(c), do: (c >= ?a and c <= ?z) or (c >= ?A and c <= ?Z) or (c >= ?0 and c <= ?9)

  # log2(pool) in tenths of a bit, rounded down (pool of 0 only for "").
  defp bits10_of_pool(pool) do
    cond do
      pool <= 0 -> 0
      pool <= 10 -> 33
      pool <= 26 -> 47
      pool <= 36 -> 51
      pool <= 52 -> 57
      pool <= 59 -> 58
      pool <= 62 -> 59
      pool <= 69 -> 61
      pool <= 85 -> 63
      true -> 65
    end
  end
end
