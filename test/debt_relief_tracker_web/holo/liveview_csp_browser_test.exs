defmodule DebtReliefTrackerWeb.Holo.LiveViewCspBrowserTest do
  # Real Chromium on the LiveView pages (`/`, `/admin`) under the enforced
  # nonce-less CSP. BrowserCase fails the test on any CSP violation.
  use DebtReliefTracker.BrowserCase

  alias DebtReliefTracker.Accounts

  setup do
    {:ok, _} = Accounts.set_tutorial_seen(Accounts.get_default_user!(), true)
    :ok
  end

  defp connected(ctx), do: wait_for_expr(ctx, "document.querySelector('.phx-connected') !== null")

  test "dashboard: LiveView connects, modals open, theme toggles, no CSP violation", ctx do
    visit(ctx, "/")

    ctx
    |> connected()
    |> click("#settings-button")
    |> assert_selector("#settings-form")
    |> press("Escape")
    |> refute_selector("#settings-form")
    |> click("#add-debt-button")
    |> assert_selector(
      "form[phx-submit=save_debt], form[phx-submit=add_debt], dialog[open], .modal"
    )
    |> press("Escape")
    |> click("[data-phx-theme=dark]")
    |> wait_for_expr("document.documentElement.getAttribute('data-theme') === 'dark'")

    assert eval(ctx, "localStorage.getItem('phx:theme')") == "dark"
  end

  test "admin: connects and switches tabs, no CSP violation", ctx do
    visit(ctx, "/admin")

    ctx
    |> connected()
    |> assert_selector("#admin-settings-form")
    |> click(~s(a[href="/admin?tab=emails"]))
    |> wait_for_expr("location.search === '?tab=emails'")
    |> refute_selector("#admin-settings-form")
    |> click("[data-phx-theme=light]")
    |> wait_for_expr("document.documentElement.getAttribute('data-theme') === 'light'")
  end
end
