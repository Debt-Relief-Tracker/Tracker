defmodule DiagBrowserTest do
  use DebtReliefTracker.BrowserCase
  alias DebtReliefTracker.BrowserCase.DiagPage
  setup_all do
    System.put_env("BROWSER_TEST_TIMEOUT_MS", "60000")
    :ok
  end
  test "diag", ctx do
    ctx = visit_page(ctx, DiagPage)
    eval(ctx, "setTimeout(() => document.getElementById('go').click(), 0), 1")
    Process.sleep(30000)
    IO.puts(eval(ctx, "window.__log"))
  end
end
