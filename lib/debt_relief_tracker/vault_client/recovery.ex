defmodule DebtReliefTracker.VaultClient.Recovery do
  @moduledoc """
  Display helpers for the recovery key shown ONCE in the setup wizard: 14
  dash-separated groups of 4 base32 characters (52 characters of key plus a
  4-character checksum, which is the final group). To prove the user really
  has it written down, the wizard requires a checkbox AND the final group typed
  back. Pure and client-safe.
  """

  @doc "The groups of a recovery key text, in order."
  def groups(key) when is_binary(key), do: String.split(key, "-")

  @doc "The final (checksum) group."
  def final_group(key) when is_binary(key), do: key |> groups() |> List.last()

  @doc """
  Whether `typed` is the final group: case, surrounding space and inner dashes
  or spaces are ignored.
  """
  def ack_ok?(key, typed) when is_binary(key) and is_binary(typed) do
    clean = typed |> String.upcase() |> String.replace("-", "") |> String.replace(" ", "")
    clean != "" and clean == String.upcase(final_group(key))
  end

  def ack_ok?(_, _), do: false
end
