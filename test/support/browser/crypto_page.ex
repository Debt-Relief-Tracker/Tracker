defmodule DebtReliefTracker.BrowserCase.CryptoPage do
  @moduledoc """
  Test-only Hologram page (compiled only in `:test`) that drives
  `DebtReliefTracker.Crypto` through real Hologram JS interop in a browser:
  each button runs one flow in an action and renders only booleans/lengths
  (never key material) so the browser test can assert on them.
  """

  use Hologram.Page

  alias DebtReliefTracker.Crypto

  route "/__browser_test/crypto"
  layout DebtReliefTrackerWeb.Holo.Layout

  def init(_params, component, _server) do
    put_state(component, :r, %{})
  end

  def template do
    ~HOLO"""
    <div id="crypto-page">
      <button id="run-flow" $click="run_flow">Argon2 + wrap + document</button>
      <button id="run-recovery" $click="run_recovery">Recovery</button>
      <button id="run-prf" $click="run_prf">PRF detect + self test</button>
      <button id="run-passkey" $click="run_passkey">Passkey</button>
      <p id="flow-done">{@r[:flow_done]}</p>
      <p id="handle-len">{@r[:handle_len]}</p>
      <p id="locked">{@r[:locked]}</p>
      <p id="unwrap-same">{@r[:unwrap_same]}</p>
      <p id="doc-text">{@r[:doc_text]}</p>
      <p id="wrong-kind">{@r[:wrong_kind]}</p>
      <p id="wrong-rev">{@r[:wrong_rev]}</p>
      <p id="bad-params">{@r[:bad_params]}</p>
      <p id="recovery-done">{@r[:recovery_done]}</p>
      <p id="recovery-same">{@r[:recovery_same]}</p>
      <p id="recovery-unwrap">{@r[:recovery_unwrap]}</p>
      <p id="recovery-bad">{@r[:recovery_bad]}</p>
      <p id="prf-done">{@r[:prf_done]}</p>
      <p id="prf-supported">{@r[:prf_supported]}</p>
      <p id="self-test">{@r[:self_test]}</p>
      <p id="passkey-done">{@r[:passkey_done]}</p>
      <p id="passkey-create">{@r[:passkey_create]}</p>
      <p id="passkey-derive">{@r[:passkey_derive]}</p>
    </div>
    """
  end

  def action(:run_flow, _params, component) do
    {:ok, h} = Crypto.new_vault()
    {:ok, wrap} = Crypto.wrap_passphrase(h, "pässphrase long", "ws1", "w1")

    {:ok, env} = Crypto.encrypt_document(h, "ws1", 3, "{\"hello\":\"wörld\"}")
    {:ok, "locked"} = Crypto.lock(h)
    locked = Crypto.decrypt_document(h, "ws1", 3, env)

    {:ok, h2} = Crypto.unlock_passphrase("pässphrase long", "ws1", Map.put(wrap, :id, "w1"))
    {:ok, text} = Crypto.decrypt_document(h2, "ws1", 3, env)
    wrong_pass = Crypto.unlock_passphrase("nope nope nope", "ws1", Map.put(wrap, :id, "w1"))
    wrong_id = Crypto.unlock_passphrase("pässphrase long", "ws1", Map.put(wrap, :id, "w2"))
    wrong_rev = Crypto.decrypt_document(h2, "ws1", 4, env)

    bad =
      Crypto.unlock_passphrase("x", "ws1", %{
        id: "w1",
        salt: wrap.salt,
        kdf_params: ~s({"memoryKiB":2000000,"iterations":3,"parallelism":1}),
        wrapped_key: wrap.wrapped_key
      })

    put_state(component, :r, %{
      flow_done: "yes",
      handle_len: to_string(byte_size(h)),
      unwrap_same: yes_no(text == "{\"hello\":\"wörld\"}"),
      doc_text: text,
      locked: inspect(locked),
      wrong_kind: inspect({wrong_pass, wrong_id}),
      wrong_rev: inspect(wrong_rev),
      bad_params: inspect(bad)
    })
  end

  def action(:run_recovery, _params, component) do
    {:ok, h} = Crypto.new_vault()
    {:ok, %{recovery_key: key, wrapped_key: wrapped}} = Crypto.wrap_recovery(h, "ws1", "r1")
    {:ok, env} = Crypto.encrypt_document(h, "ws1", 1, "secret")
    wrap = %{id: "r1", wrapped_key: wrapped}
    {:ok, h2} = Crypto.unlock_recovery(String.downcase(key), "ws1", wrap)
    {:ok, text} = Crypto.decrypt_document(h2, "ws1", 1, env)
    bad = Crypto.unlock_recovery("not a key", "ws1", wrap)

    put_state(component, :r, %{
      recovery_done: "yes",
      recovery_same: yes_no(String.length(key) == 69),
      recovery_unwrap: yes_no(text == "secret"),
      recovery_bad: inspect(bad)
    })
  end

  def action(:run_prf, _params, component) do
    put_state(component, :r, %{
      prf_done: "yes",
      prf_supported: yes_no(Crypto.prf_supported?()),
      self_test: inspect(Crypto.self_test())
    })
  end

  def action(:run_passkey, _params, component) do
    {:ok, h} = Crypto.new_vault()

    opts = %{rp_id: "localhost", rp_name: "DRT test", user_name: "tester"}

    case Crypto.wrap_passkey(h, "ws1", "p1", opts) do
      {:ok, %{credential_id: id, wrapped_key: wrapped}} ->
        wrap = %{id: "p1", credential_id: id, wrapped_key: wrapped}
        {:ok, env} = Crypto.encrypt_document(h, "ws1", 1, "pk")
        {:ok, h2} = Crypto.unlock_passkey("ws1", "localhost", wrap)
        {:ok, text} = Crypto.decrypt_document(h2, "ws1", 1, env)

        put_state(component, :r, %{
          passkey_done: "yes",
          passkey_create: "ok",
          passkey_derive: yes_no(text == "pk")
        })

      {:error, code} ->
        put_state(component, :r, %{passkey_done: "yes", passkey_create: inspect(code)})
    end
  end

  defp yes_no(true), do: "yes"
  defp yes_no(false), do: "no"
end
