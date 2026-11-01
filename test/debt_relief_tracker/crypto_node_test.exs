defmodule DebtReliefTracker.CryptoNodeTest do
  @moduledoc """
  Runs the Node known-answer + behavioural suite for the browser crypto facade
  (`assets/test/crypto_facade.test.mjs`, via `node --test`). Skipped with a
  message if `node` or `assets/node_modules/hash-wasm` is missing.
  """
  use ExUnit.Case, async: true

  @assets Path.expand("../../assets", __DIR__)

  @tag timeout: 120_000
  test "node --test passes for assets/test/crypto_facade.test.mjs" do
    cond do
      is_nil(System.find_executable("node")) ->
        IO.puts("SKIP crypto facade node tests: `node` not found on PATH")

      not File.dir?(Path.join(@assets, "node_modules/hash-wasm")) ->
        IO.puts("SKIP crypto facade node tests: run `npm install --prefix assets` first")

      true ->
        {out, status} =
          System.cmd("node", ["--test", "test/crypto_facade.test.mjs"],
            cd: @assets,
            stderr_to_stdout: true
          )

        assert status == 0, "node --test failed:\n" <> out
    end
  end
end
