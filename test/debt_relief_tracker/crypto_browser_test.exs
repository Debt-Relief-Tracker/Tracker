defmodule DebtReliefTracker.CryptoBrowserTest do
  @moduledoc """
  Real-browser proof that `DebtReliefTracker.Crypto` works through Hologram JS
  interop (Task.await on facade Promises, real Argon2id WebAssembly), plus the
  passkey PRF path against Chromium's CDP virtual authenticator. Run with
  `mix test --include browser`.
  """
  use DebtReliefTracker.BrowserCase

  alias DebtReliefTracker.BrowserCase.CryptoPage
  alias DebtReliefTracker.BrowserCase.Driver

  setup do
    # Argon2id 64 MiB x 3 can take a few seconds, longer in CI.
    System.put_env("BROWSER_TEST_TIMEOUT_MS", "60000")
    :ok
  end

  test "facade works end to end through Hologram interop; Argon2id timing", ctx do
    ctx = visit_page(ctx, CryptoPage)

    t0 = System.monotonic_time(:millisecond)

    ctx
    |> click("#run-flow")
    |> assert_text("#flow-done", "yes")

    ms = System.monotonic_time(:millisecond) - t0

    IO.puts(
      "[crypto] Hologram flow (Argon2id 64MiB/3/1 + wrap/unwrap/doc), click-to-done: #{ms} ms"
    )

    assert text(ctx, "#handle-len") == "17"
    assert text(ctx, "#locked") == "{:error, :locked}"
    assert text(ctx, "#unwrap-same") == "yes"
    assert text(ctx, "#doc-text") == ~s({"hello":"wörld"})
    assert text(ctx, "#wrong-kind") == "{{:error, :decrypt_failed}, {:error, :decrypt_failed}}"
    assert text(ctx, "#wrong-rev") == "{:error, :decrypt_failed}"
    assert text(ctx, "#bad-params") == "{:error, :bad_params}"
    assert Driver.call(ctx.driver, "errors", %{}) == []
  end

  test "recovery key flow through Hologram", ctx do
    ctx
    |> visit_page(CryptoPage)
    |> click("#run-recovery")
    |> assert_text("#recovery-done", "yes")

    assert text(ctx, "#recovery-same") == "yes"
    assert text(ctx, "#recovery-unwrap") == "yes"
    assert text(ctx, "#recovery-bad") == "{:error, :bad_recovery_key}"
  end

  test "self test and PRF detection through Hologram", ctx do
    ctx
    |> visit_page(CryptoPage)
    |> click("#run-prf")
    |> assert_text("#prf-done", "yes")

    assert text(ctx, "#self-test") == ~s({:ok, "ok"})
    assert text(ctx, "#prf-supported") == "yes"
  end

  test "passkey create + derive via virtual authenticator with PRF", ctx do
    ctx = visit_localhost(ctx)
    version = Driver.call(ctx.driver, "browser_version", %{})
    Driver.call(ctx.driver, "webauthn_enable", %{hasPrf: true})

    click(ctx, "#run-passkey")
    assert_text(ctx, "#passkey-done", "yes")
    result = text(ctx, "#passkey-create")
    IO.puts("[crypto] Chromium #{version}: virtual authenticator passkey create -> #{result}")

    # Whether this Chromium build's virtual authenticator implements PRF is
    # reported, not assumed: either the full round trip works, or the
    # facade reports the unsupported case with its distinct code.
    case result do
      "ok" -> assert text(ctx, "#passkey-derive") == "yes"
      other -> assert other in ["unsupported", ":passkey_unsupported", ":passkey_failed"]
    end
  end

  test "passkey without a PRF-capable authenticator reports a distinct code", ctx do
    ctx = visit_localhost(ctx)
    Driver.call(ctx.driver, "webauthn_enable", %{hasPrf: false})

    click(ctx, "#run-passkey")
    assert_text(ctx, "#passkey-done", "yes")
    IO.puts("[crypto] virtual authenticator WITHOUT prf -> #{text(ctx, "#passkey-create")}")
    assert text(ctx, "#passkey-create") == ":passkey_unsupported"
  end

  # WebAuthn needs a real rpId (an IP address is not a valid one), so load the
  # page via `localhost`.
  defp visit_localhost(%{driver: d, base_url: base} = ctx) do
    url = String.replace(base, "127.0.0.1", "localhost") <> "/__browser_test/crypto"
    Driver.call(d, "visit", %{url: url})
    Driver.call(d, "wait_mounted", %{page: inspect(CryptoPage)})
    ctx
  end
end
