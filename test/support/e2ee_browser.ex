defmodule DebtReliefTracker.E2EEBrowser do
  @moduledoc """
  Helpers for real-browser tests of the E2EE client flows (use next to
  `DebtReliefTracker.BrowserCase`). The app is loaded through `localhost`, not
  `127.0.0.1`: WebAuthn needs a real rpId, and IndexedDB / BroadcastChannel are
  per origin, so every tab of one test uses the same origin.
  """

  import DebtReliefTracker.BrowserCase
  import ExUnit.Assertions, only: [refute: 2]
  import DebtReliefTracker.BrowserExtras, only: [js: 2]

  alias DebtReliefTracker.BrowserCase.Driver
  alias DebtReliefTrackerWeb.Holo.DashboardPage

  @doc "Turns E2EE on for this test and restores config afterwards."
  def e2ee_on(opts \\ []) do
    DebtReliefTracker.E2EEHelpers.enable_e2ee()
    put_env(:e2ee_test_hook, Keyword.get(opts, :hook, true))
    put_env(:e2ee_idle_ms, Keyword.get(opts, :idle_ms, 900_000))
    :ok
  end

  defp put_env(key, value) do
    old = Application.fetch_env(:debt_relief_tracker, key)
    Application.put_env(:debt_relief_tracker, key, value)

    ExUnit.Callbacks.on_exit(fn ->
      case old do
        {:ok, v} -> Application.put_env(:debt_relief_tracker, key, v)
        :error -> Application.delete_env(:debt_relief_tracker, key)
      end
    end)
  end

  def localhost(%{base_url: base}), do: String.replace(base, "127.0.0.1", "localhost")

  @doc "Opens /app through localhost and waits for the Hologram page to mount."
  def open_app(%{driver: d} = ctx) do
    Driver.call(d, "visit", %{url: localhost(ctx) <> "/app"})
    Driver.call(d, "wait_mounted", %{page: inspect(DashboardPage)})
    ctx
  end

  @doc "Opens a second tab (same browser context) on /app; returns a ctx addressing it."
  def new_tab(%{driver: d} = ctx, name) do
    Driver.call(d, "new_tab", %{name: name})
    tab = %{ctx | driver: {base_port(d), name}}
    open_app(tab)
  end

  def tab(%{driver: d} = ctx, name), do: %{ctx | driver: {base_port(d), name}}

  defp base_port({port, _tab}), do: port
  defp base_port(port), do: port

  @doc "Reloads the current tab and waits for the page."
  def reload(%{driver: d} = ctx) do
    Driver.call(d, "reload", %{})
    Driver.call(d, "wait_mounted", %{page: inspect(DashboardPage)})
    ctx
  end

  @doc """
  Walks the setup wizard with a passphrase and returns `{ctx, recovery_key}`;
  ends on the unlocked home screen.
  """
  def create_vault(ctx, passphrase, opts \\ []) do
    ctx =
      ctx
      |> assert_selector("#vault-setup")
      |> click("#setup-method-passphrase")
      |> fill("#setup-passphrase", passphrase)
      |> fill("#setup-confirm", passphrase)

    ctx = if opts[:remember], do: check(ctx, "#setup-remember"), else: ctx

    ctx
    |> click("#setup-continue")
    |> assert_selector("#setup-recovery-key")

    key = recovery_key_on_screen(ctx, "#setup-recovery-key")
    final = key |> String.split("-") |> List.last()

    ctx
    |> check("#setup-ack-saved")
    |> fill("#setup-ack-final", final)
    |> click("#setup-finish")
    |> assert_selector("#vault-home")

    {ctx, key}
  end

  def recovery_key_on_screen(ctx, selector) do
    js(
      ctx,
      "Array.from(document.querySelectorAll(#{JSON.encode!(selector)} + ' .recovery-group')).map(e => e.textContent.trim()).join('-')"
    )
  end

  def unlock_with_passphrase(ctx, passphrase) do
    ctx
    |> assert_selector("#unlock-passphrase-form")
    |> fill("#unlock-passphrase-input", passphrase)
    |> click("#unlock-passphrase-submit")
  end

  def lock(ctx) do
    ctx |> click("#vault-lock-btn") |> assert_selector("#vault-unlock")
  end

  @doc "Adds a debt through the test hook and waits until it is listed."
  def add_debt(ctx, name) do
    ctx
    |> fill("#test-hook-name", name)
    |> click("#test-hook-add")
    |> assert_text("#vault-debts", name)
  end

  def status(ctx), do: attr(ctx, "#vault-sync-status", "data-status")

  def wait_status(ctx, status) do
    wait_for_expr(
      ctx,
      "document.querySelector('#vault-sync-status')?.dataset.status === #{JSON.encode!(status)}"
    )
  end

  def storage_dump(%{driver: d}), do: Driver.call(d, "storage_dump", %{})

  # --- out-of-band helpers ---------------------------------------------------

  def workspace, do: DebtReliefTracker.Accounts.ensure_default_workspace!()

  def server_vault do
    {:ok, vault} = DebtReliefTracker.E2EE.Vaults.fetch(workspace())
    vault
  end

  @doc "A well-formed recovery key (valid checksum) that unlocks nothing."
  def foreign_recovery_key do
    bytes = :crypto.strong_rand_bytes(32)
    <<check::binary-size(3), _::binary>> = :crypto.hash(:sha256, "drt-recovery-check-v1" <> bytes)
    key = Base.encode32(bytes, padding: false)
    # 256 bits -> 52 chars (the last carries 4 zero pad bits)
    checksum = check |> Base.encode32(padding: false) |> binary_part(0, 4)

    (key <> checksum)
    |> String.graphemes()
    |> Enum.chunk_every(4)
    |> Enum.map_join("-", &Enum.join/1)
  end

  def wait_until(fun, tries \\ 100) do
    cond do
      fun.() ->
        :ok

      tries == 0 ->
        raise "wait_until timed out"

      true ->
        Process.sleep(100)
        wait_until(fun, tries - 1)
    end
  end

  @doc "Every row of every table on the server (the proof that only ciphertext is stored)."
  def all_rows do
    repo = DebtReliefTracker.Repo.active_repo()

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

  @doc """
  Fails when any `marker` string occurs in any row of any table (as text, so
  binary columns are scanned too) -- run after a flow that used the markers
  in names / notes.
  """
  def refute_in_database(markers) do
    rows = all_rows()

    for marker <- markers do
      refute contains?(rows, marker), "#{marker} found in the server database"
    end

    :ok
  end

  defp contains?(bin, marker) when is_binary(bin), do: :binary.match(bin, marker) != :nomatch
  defp contains?(list, marker) when is_list(list), do: Enum.any?(list, &contains?(&1, marker))
  defp contains?(tuple, marker) when is_tuple(tuple), do: contains?(Tuple.to_list(tuple), marker)
  defp contains?(%{} = map, marker), do: contains?(Map.to_list(map), marker)
  defp contains?(other, marker), do: contains?(inspect(other), marker)
end
