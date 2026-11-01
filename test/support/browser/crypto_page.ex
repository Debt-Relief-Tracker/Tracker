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
      <p id="kek-bytes">{@r[:kek_bytes]}</p>
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
    {:ok, vk} = Crypto.generate_vault_key()
    {:ok, salt} = Crypto.new_salt()

    {:ok, kek} =
      Crypto.derive_new_passphrase_kek("pässphrase", salt, Crypto.default_argon2_params())

    {:ok, wrap} = Crypto.wrap_vault_key(kek, vk, "ws1", "w1", :passphrase)
    {:ok, vk2} = Crypto.unwrap_vault_key(kek, wrap, "ws1", "w1", :passphrase)
    {:ok, env} = Crypto.encrypt_document(vk, "ws1", 3, "{\"hello\":\"wörld\"}")
    {:ok, text} = Crypto.decrypt_document(vk2, "ws1", 3, env)
    wrong_kind = Crypto.unwrap_vault_key(kek, wrap, "ws1", "w1", :recovery)
    wrong_rev = Crypto.decrypt_document(vk, "ws1", 4, env)

    bad =
      Crypto.derive_passphrase_kek("x", salt, %{
        memory_kib: 2_000_000,
        iterations: 3,
        parallelism: 1
      })

    put_state(component, :r, %{
      flow_done: "yes",
      kek_bytes: to_string(byte_size(kek)),
      unwrap_same: yes_no(vk == vk2),
      doc_text: text,
      wrong_kind: inspect(wrong_kind),
      wrong_rev: inspect(wrong_rev),
      bad_params: inspect(bad)
    })
  end

  def action(:run_recovery, _params, component) do
    {:ok, key} = Crypto.generate_recovery_key()
    {:ok, kek1} = Crypto.derive_recovery_kek(key)
    {:ok, kek2} = Crypto.derive_recovery_kek(String.downcase(key))
    {:ok, vk} = Crypto.generate_vault_key()
    {:ok, wrap} = Crypto.wrap_vault_key(kek1, vk, "ws1", "r1", :recovery)
    {:ok, vk2} = Crypto.unwrap_vault_key(kek2, wrap, "ws1", "r1", :recovery)
    bad = Crypto.derive_recovery_kek("not a key")

    put_state(component, :r, %{
      recovery_done: "yes",
      recovery_same: yes_no(kek1 == kek2),
      recovery_unwrap: yes_no(vk == vk2),
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
    opts = %{
      rp_id: "localhost",
      rp_name: "DRT test",
      user_id: "AQIDBA",
      user_name: "tester",
      display_name: "Tester"
    }

    case Crypto.create_passkey(opts) do
      {:ok, %{credential_id: id, kek: kek}} ->
        {:ok, kek2} = Crypto.derive_passkey_kek(id, "localhost")

        put_state(component, :r, %{
          passkey_done: "yes",
          passkey_create: "ok",
          passkey_derive: yes_no(kek == kek2)
        })

      {:error, code} ->
        put_state(component, :r, %{passkey_done: "yes", passkey_create: inspect(code)})
    end
  end

  defp yes_no(true), do: "yes"
  defp yes_no(false), do: "no"
end
