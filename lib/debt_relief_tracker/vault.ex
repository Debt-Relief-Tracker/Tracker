defmodule DebtReliefTracker.Vault do
  @moduledoc """
  Cloak vault backing the `DebtReliefTracker.Encrypted.*` Ecto types
  (docs/architecture/0005-field-level-encryption.md).

  The key comes from `ENCRYPTION_KEY` in prod (config/runtime.exs, same
  required-in-prod/raise-if-missing pattern as `SECRET_KEY_BASE`) and a
  fixed dummy value in dev/test (config/dev.exs, config/test.exs).

  Losing this key makes every encrypted column permanently unreadable --
  database backups do not help, since they contain the same ciphertext.
  """

  use Cloak.Vault, otp_app: :debt_relief_tracker

  @impl GenServer
  def init(config) do
    key = config |> Keyword.fetch!(:key) |> decode_key!()

    config =
      Keyword.put(config, :ciphers,
        default: {Cloak.Ciphers.AES.GCM, tag: "AES.GCM.V1", key: key, iv_length: 12}
      )

    {:ok, config}
  end

  defp decode_key!(encoded) do
    case Base.decode64(encoded) do
      {:ok, <<key::binary-32>>} ->
        key

      _ ->
        raise ArgumentError, """
        ENCRYPTION_KEY must be 32 random bytes, base64-encoded. Generate one with:

            elixir -e ':crypto.strong_rand_bytes(32) |> Base.encode64() |> IO.puts()'
        """
    end
  end
end
