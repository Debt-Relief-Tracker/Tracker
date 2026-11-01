defmodule DebtReliefTracker.CryptoCspBrowserTest do
  @moduledoc """
  Verifies the crypto facade (with its bundled hash-wasm Argon2id) under the
  strict CSP proposed in ADR 0007, in real Chromium, and times Argon2id at
  64 MiB / 3 iterations / 1 lane. Uses a throwaway loopback static server in
  `test/browser/csp_check.mjs` (Hologram's own inline scripts are covered by
  the nonce work in the ADR, not here). Run with `mix test --include browser`.
  """
  use ExUnit.Case, async: false

  @moduletag :browser
  @moduletag timeout: 120_000

  test "facade + Argon2 WASM need 'wasm-unsafe-eval' and nothing else; timing" do
    chromium = chromium_path()
    esbuild = Esbuild.bin_path()

    {out, 0} =
      System.cmd("node", ["csp_check.mjs", esbuild, chromium, "7"],
        cd: Path.expand("../browser", __DIR__),
        stderr_to_stdout: false
      )

    report = out |> String.split("\n", trim: true) |> List.last() |> JSON.decode!()
    IO.puts("[crypto] CSP/timing report: #{JSON.encode!(report)}")

    ok = report["withWasmUnsafeEval"]
    assert ok["selfTest"] == "ok"
    assert ok["kekLen"] == 43
    assert ok["consoleErrors"] == []
    assert length(ok["argon2Ms"]) == 7

    # Without 'wasm-unsafe-eval' WebAssembly compilation is refused, so
    # Argon2id (and the self test that includes it) cannot run.
    no = report["withoutWasmUnsafeEval"]
    assert String.starts_with?(no["argon2"], "FAIL:")
    assert no["selfTest"] =~ "FAIL"
  end

  defp chromium_path do
    System.get_env("CHROMIUM_PATH") ||
      Enum.find(
        Path.wildcard(
          Path.expand(
            "~/.cache/ms-playwright/chromium_headless_shell-*/chrome-linux/headless_shell"
          )
        ),
        &File.exists?/1
      ) || flunk("no cached Chromium; set CHROMIUM_PATH")
  end
end
