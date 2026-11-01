defmodule DebtReliefTrackerWeb.Holo.E2EESyncBrowserTest do
  @moduledoc """
  Real-Chromium tests of the save/sync loop (roadmap Phase 8: compare-and-swap,
  merge on conflict, debounce, unload warning, refetch on visibility) and the
  end-to-end "no plaintext anywhere" proof.
  """
  use DebtReliefTracker.BrowserCase

  import DebtReliefTracker.E2EEBrowser
  import DebtReliefTracker.BrowserExtras, only: [js: 2, errors: 1]
  import ExUnit.CaptureLog

  alias DebtReliefTracker.BrowserCase.Driver
  alias DebtReliefTracker.Repo

  @pass "correct horse battery staple 77"

  setup do
    e2ee_on()
    :ok
  end

  test "an edit is applied locally at once, then saved after the debounce with a new revision",
       ctx do
    ctx = open_app(ctx)
    {ctx, _} = create_vault(ctx, @pass)
    assert status(ctx) in ["idle", "saved"]

    add_debt(ctx, "Debounced card")
    # shown immediately, but not yet on the server
    assert status(ctx) in ["dirty", "saving", "saved"]
    wait_status(ctx, "saved")
    assert server_vault().rev == 2

    # a second edit => rev 3, ciphertext differs each time (fresh IV)
    blob2 = server_vault().blob
    add_debt(ctx, "Second card")
    wait_until(fn -> server_vault().rev == 3 end)
    refute server_vault().blob == blob2
    wait_status(ctx, "saved")
    assert errors(ctx) == []

    # lock + unlock restores the document from the server
    ctx = lock(ctx)
    unlock_with_passphrase(ctx, @pass)
    assert_text(ctx, "#vault-debts", "Debounced card")
    assert text(ctx, "#vault-debts") =~ "Second card"
  end

  test "payments change balances through the ledger and survive a lock", ctx do
    ctx = open_app(ctx)
    {ctx, _} = create_vault(ctx, @pass)
    add_debt(ctx, "Visa")
    assert_text(ctx, ".vault-debt-balance", "1,000.00")

    [id] =
      js(ctx, "Array.from(document.querySelectorAll('.vault-debt')).map(e => e.id.slice(11))")

    click(ctx, "#vault-pay-#{id}")
    assert_text(ctx, ".vault-debt-balance", "990.00")
    assert_text(ctx, "#vault-payments-count", "1 payments")
    wait_status(ctx, "saved")

    ctx = lock(ctx)
    unlock_with_passphrase(ctx, @pass)
    assert_text(ctx, ".vault-debt-balance", "990.00")
    assert text(ctx, "#vault-payments-count") =~ "1 payments"
  end

  test "concurrent edits in two tabs: CAS conflict, merge, both changes survive", ctx do
    ctx_a = open_app(ctx)
    {ctx_a, _} = create_vault(ctx_a, @pass)
    ctx_b = new_tab(ctx, "b")
    unlock_with_passphrase(ctx_b, @pass)
    assert_selector(ctx_b, "#vault-home")

    # both edit from revision 1 inside the same debounce window
    add_debt(ctx_a, "Debt from A")
    add_debt(ctx_b, "Debt from B")
    wait_until(fn -> server_vault().rev >= 3 end, 150)
    wait_status(ctx_a, "saved")
    wait_status(ctx_b, "saved")
    assert server_vault().rev == 3

    # the tab that lost the race merged and shows both right away
    both = fn ctx_x ->
      t = text(ctx_x, "#vault-debts")
      t =~ "Debt from A" and t =~ "Debt from B"
    end

    assert Enum.any?([ctx_a, ctx_b], both)

    # the other one catches up when its tab becomes visible again (refetch + merge)
    js(ctx_a, "document.dispatchEvent(new Event('visibilitychange'))")
    js(ctx_b, "document.dispatchEvent(new Event('visibilitychange'))")

    wait_for_expr(
      ctx_a,
      "document.querySelector('#vault-debts').innerText.includes('Debt from B')"
    )

    wait_for_expr(
      ctx_b,
      "document.querySelector('#vault-debts').innerText.includes('Debt from A')"
    )

    # and the server copy has both (decrypted by a fresh unlock)
    ctx_a = lock(ctx_a)
    unlock_with_passphrase(ctx_a, @pass)

    wait_for_expr(
      ctx_a,
      "document.querySelector('#vault-debts').innerText.includes('Debt from B')"
    )

    assert text(ctx_a, "#vault-debts") =~ "Debt from A"
    assert errors(ctx_a) == []
  end

  test "concurrent payments in two tabs both reduce the balance", ctx do
    ctx_a = open_app(ctx)
    {ctx_a, _} = create_vault(ctx_a, @pass)
    add_debt(ctx_a, "Shared card")
    wait_status(ctx_a, "saved")

    [id] =
      js(ctx_a, "Array.from(document.querySelectorAll('.vault-debt')).map(e => e.id.slice(11))")

    ctx_b = new_tab(ctx, "b")
    unlock_with_passphrase(ctx_b, @pass)
    assert_text(ctx_b, ".vault-debt-balance", "1,000.00")

    click(ctx_a, "#vault-pay-#{id}")
    click(ctx_b, "#vault-pay-#{id}")
    wait_until(fn -> server_vault().rev >= 4 end, 150)
    wait_status(ctx_a, "saved")
    wait_status(ctx_b, "saved")
    js(ctx_a, "document.dispatchEvent(new Event('visibilitychange'))")
    js(ctx_b, "document.dispatchEvent(new Event('visibilitychange'))")

    wait_for_expr(
      ctx_a,
      "document.querySelector('.vault-debt-balance').innerText.includes('980.00')"
    )

    wait_for_expr(
      ctx_b,
      "document.querySelector('.vault-debt-balance').innerText.includes('980.00')"
    )
  end

  test "leaving with unsaved changes warns; once saved it does not", ctx do
    ctx = open_app(ctx)
    {ctx, _} = create_vault(ctx, @pass)
    refute Driver.call(ctx.driver, "beforeunload_prevented", %{})
    add_debt(ctx, "Unsaved card")
    assert Driver.call(ctx.driver, "beforeunload_prevented", %{})
    wait_status(ctx, "saved")
    refute Driver.call(ctx.driver, "beforeunload_prevented", %{})
  end

  test "a failed save is retried and a dirty change is not dropped (offline then back)", ctx do
    ctx = open_app(ctx)
    {ctx, _} = create_vault(ctx, @pass)

    # take the vault row away from under the client: the save fails (not_found)
    {:ok, vault} = DebtReliefTracker.E2EE.Vaults.fetch(workspace())
    wraps = vault.key_wraps
    Repo.delete_all(DebtReliefTracker.E2EE.Vault)
    add_debt(ctx, "Pending card")
    wait_status(ctx, "offline")
    assert Driver.call(ctx.driver, "beforeunload_prevented", %{}), "still protected from unload"
    assert text(ctx, "#vault-debts") =~ "Pending card"

    # the vault comes back: the retry succeeds without losing the change
    Repo.insert!(%DebtReliefTracker.E2EE.Vault{
      workspace_id: workspace().id,
      rev: 1,
      format_version: 1,
      blob: vault.blob
    })

    assert length(wraps) == 2
    wait_status(ctx, "saved")
    assert server_vault().rev == 2
  end

  test "NOTHING sensitive reaches the server DB, logs, cookies, URLs or browser storage", ctx do
    marker = "ZQXMARKERDEBT" <> Integer.to_string(System.unique_integer([:positive]))
    pass = "ZQXPASSPHRASE-unique-" <> Integer.to_string(System.unique_integer([:positive]))

    old_level = Logger.level()
    Logger.configure(level: :debug)
    on_exit(fn -> Logger.configure(level: old_level) end)

    {log, {ctx, recovery}} =
      with_log([level: :debug], fn ->
        ctx = open_app(ctx)
        {ctx, recovery} = create_vault(ctx, pass, remember: true)
        add_debt(ctx, marker)
        wait_status(ctx, "saved")
        add_debt(ctx, marker <> "-two")
        wait_until(fn -> server_vault().rev == 3 end)
        wait_status(ctx, "saved")
        ctx = lock(ctx)
        unlock_with_passphrase(ctx, pass)
        assert_text(ctx, "#vault-debts", marker)
        click(ctx, "#vault-methods-btn")
        fill(ctx, "#methods-old-passphrase", pass)
        fill(ctx, "#methods-new-passphrase", pass <> "-changed")
        fill(ctx, "#methods-new-confirm", pass <> "-changed")
        click(ctx, "#methods-change-submit")
        assert_text(ctx, "#methods-status", "Done")
        {ctx, recovery}
      end)

    secrets = [
      marker,
      pass,
      recovery,
      String.replace(recovery, "-", ""),
      String.downcase(recovery)
    ]

    # 1. every row of every table, raw
    rows = all_rows()
    refute rows == []

    raw =
      :erlang.term_to_binary(rows) <> inspect(rows, limit: :infinity, printable_limit: :infinity)

    for secret <- secrets do
      refute String.contains?(raw, secret), "secret leaked into the database"
      refute String.contains?(raw, Base.encode64(secret)), "base64 secret in the database"
      refute String.contains?(raw, Base.url_encode64(secret, padding: false))
    end

    # 2. server logs
    for secret <- secrets, do: refute(log =~ secret, "secret leaked into the server log")

    # 3. browser storage
    dump = storage_dump(ctx)
    stored = JSON.encode!(dump)
    for secret <- secrets, do: refute(stored =~ secret, "secret in browser storage")
    assert dump["cookie"] == "" or not (dump["cookie"] =~ marker)
    assert Map.drop(dump["local"], ["phx:theme"]) == %{}
    assert dump["session"] == %{}

    cookies = JSON.encode!(Driver.call(ctx.driver, "cookies", %{}))
    for secret <- secrets, do: refute(cookies =~ secret)

    # IndexedDB: only the allowed records
    assert Map.keys(dump["idb"]) == ["drt-vault"]
    idb = dump["idb"]["drt-vault"]
    assert Enum.sort(Map.keys(idb)) == ["device_keys", "seen"]
    assert [%{"type" => "CryptoKey", "value" => %{"extractable" => false}}] = idb["device_keys"]
    assert [%{"value" => %{"rev" => rev, "hash" => hash}}] = idb["seen"]
    assert is_integer(rev) and is_binary(hash)

    # URLs
    url = js(ctx, "location.href")
    for secret <- secrets, do: refute(url =~ secret)
    assert errors(ctx) == []

    # sanity: the data really is in the vault (decrypts to the marker after a fresh unlock)
    ctx = reload(ctx)
    assert_selector(ctx, "#vault-home")
    assert_text(ctx, "#vault-debts", marker)
  end

  defp all_rows do
    repo = DebtReliefTracker.Repo

    tables =
      case repo.__adapter__() do
        Ecto.Adapters.Postgres ->
          %{rows: rows} =
            Ecto.Adapters.SQL.query!(
              repo,
              "SELECT tablename FROM pg_tables WHERE schemaname = current_schema()",
              []
            )

          List.flatten(rows)

        _ ->
          %{rows: rows} =
            Ecto.Adapters.SQL.query!(
              repo,
              "SELECT name FROM sqlite_master WHERE type = 'table'",
              []
            )

          List.flatten(rows)
      end

    for table <- tables, table != "schema_migrations" do
      %{rows: rows} = Ecto.Adapters.SQL.query!(repo, ~s(SELECT * FROM "#{table}"), [])
      {table, rows}
    end
  end
end
