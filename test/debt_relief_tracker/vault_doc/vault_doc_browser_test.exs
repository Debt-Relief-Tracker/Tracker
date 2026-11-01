defmodule DebtReliefTracker.VaultDoc.BrowserTest do
  @moduledoc """
  The compiled (JavaScript) ledger/merge/JSON gives byte-for-byte the output
  ExUnit gets for the same fixed script. Run with `mix test --include browser`.
  """
  use DebtReliefTracker.BrowserCase

  alias DebtReliefTracker.BrowserCase.VaultDocPage

  setup_all do
    System.put_env("BROWSER_TEST_TIMEOUT_MS", "170000")
    :ok
  end

  test "the browser-compiled vault ledger matches the BEAM byte for byte", ctx do
    {:ok, agent} = Agent.start_link(fn -> 0 end)

    new_id = fn ->
      n = Agent.get_and_update(agent, &{&1 + 1, &1 + 1})
      "id-" <> String.pad_leading(Integer.to_string(n), 4, "0")
    end

    expected = DebtReliefTracker.VaultDocScript.run(new_id)

    ctx = visit_page(ctx, VaultDocPage)
    # don't block on the click: the compiled script can take a while
    eval(ctx, "setTimeout(() => document.getElementById('run-script').click(), 0), 1")
    t0 = System.monotonic_time(:millisecond)

    wait_for_expr(ctx, "document.getElementById('script-out').textContent.length > 10")
    IO.puts("[vault_doc] compiled script took #{System.monotonic_time(:millisecond) - t0} ms")

    actual = eval(ctx, "document.getElementById('script-out').textContent")
    assert byte_size(actual) == byte_size(expected)
    assert actual == expected
  end
end
