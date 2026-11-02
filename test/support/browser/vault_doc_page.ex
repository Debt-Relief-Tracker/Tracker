defmodule DebtReliefTracker.BrowserCase.VaultDocPage do
  @moduledoc """
  Test-only Hologram page (compiled only in `:test`) that runs
  `DebtReliefTracker.VaultDocScript` -- the compiled, client-side vault
  ledger, merge and JSON -- in a real browser and renders the resulting JSON
  string, so a `:browser` test can compare it byte for byte with ExUnit's.
  Ids come from a counter kept on `window` (the ledger takes an id source;
  production passes a UUID generator).
  """

  use Hologram.Page
  use Hologram.JS

  alias DebtReliefTracker.VaultDocScript

  route "/__browser_test/vault_doc"
  layout DebtReliefTrackerWeb.Holo.Layout

  def init(_params, component, _server), do: put_state(component, :out, "")

  def template do
    ~HOLO"""
    <div id="vault-doc-page">
      <button id="run-script" $click="run_script">run</button>
      <pre id="script-out">{@out}</pre>
    </div>
    """
  end

  def action(:run_script, _params, component) do
    DebtReliefTrackerWeb.Holo.QuietJS.quiet()
    JS.set(:window, :__vault_ids, 0)

    new_id = fn ->
      n = JS.get(:window, :__vault_ids) + 1
      JS.set(:window, :__vault_ids, n)
      "id-" <> String.pad_leading(Integer.to_string(n), 4, "0")
    end

    put_state(component, :out, VaultDocScript.run(new_id))
  end
end
