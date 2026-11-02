defmodule DebtReliefTrackerWeb.Holo.BlobHash do
  @moduledoc """
  Browser-side SHA-256 (lowercase hex) of a vault blob string, so the
  migration finalize can be bound to the exact blob that was verified
  (`E2EE.Migration.finalize/4`). Call from a Hologram action only.
  """

  use Hologram.JS

  js_import from: "../../../assets/js/blob_hash.mjs", as: :BlobHash

  @doc "`{:ok, hex}` or `{:error, :hash_failed}` (also outside a browser)."
  def sha256_hex(blob) when is_binary(blob) do
    case JS.call(:BlobHash, :sha256Hex, [blob]) do
      :ok ->
        {:error, :hash_failed}

      task ->
        case Task.await(task) do
          "ok:" <> hex -> {:ok, hex}
          _ -> {:error, :hash_failed}
        end
    end
  end

  def sha256_hex(_other), do: {:error, :hash_failed}
end
