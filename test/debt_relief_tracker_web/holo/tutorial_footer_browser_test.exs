defmodule DebtReliefTrackerWeb.Holo.TutorialFooterBrowserTest do
  # Real-browser tests of the first-run tutorial overlay and the footer /
  # donate modal (run with `mix test --include browser`).
  use DebtReliefTracker.BrowserCase

  import DebtReliefTracker.BrowserExtras

  alias DebtReliefTracker.{Accounts, Debts}
  alias DebtReliefTrackerWeb.Holo.DashboardPage

  setup do
    workspace = Accounts.ensure_default_workspace!()

    for {name, balance} <- [{"Browser Visa", "4500.00"}, {"Store card", "800.00"}] do
      {:ok, _} =
        Debts.create_debt(workspace, nil, %{
          "name" => name,
          "type" => "revolving",
          "balance" => balance,
          "apr" => "12.99",
          "minimum_payment_floor" => "35.00",
          "minimum_payment_rate" => "0.02"
        })
    end

    :ok
  end

  defp seen!(seen?),
    do: {:ok, _} = Accounts.set_tutorial_seen(Accounts.get_default_user!(), seen?)

  defp tutorial_seen?, do: Accounts.get_default_user!().tutorial_seen

  # The spotlight hole must surround the target, the card must be on screen
  # and must not cover the target.
  defp assert_sane_geometry(ctx, target) do
    wait_js(
      ctx,
      "document.querySelector('#tutorial-card')?.getAttribute('data-target') === #{JSON.encode!(target)}"
    )

    # wait for the card to be positioned next to the target (not centred)
    wait_js(
      ctx,
      "!document.querySelector('#tutorial-card').style.transform.includes('translate')"
    )

    card = rect(ctx, "#tutorial-card")
    {vw, vh} = viewport(ctx)
    t = rect(ctx, target)

    assert t, "target #{target} missing"
    assert t["w"] > 0 and t["h"] > 0, "target #{target} has no size"

    assert card["x"] >= 0 and card["r"] <= vw + 1,
           "card horizontally off screen: #{inspect(card)}"

    assert card["y"] >= 0 and card["b"] <= vh + 1, "card vertically off screen: #{inspect(card)}"

    overlap_x = min(card["r"], t["r"]) - max(card["x"], t["x"])
    overlap_y = min(card["b"], t["b"]) - max(card["y"], t["y"])
    refute overlap_x > 2 and overlap_y > 2, "card covers target #{target}: #{inspect({card, t})}"

    # target is in the viewport (scrolled into view)
    assert t["y"] >= -1 and t["b"] <= vh + 1, "target outside viewport: #{inspect(t)}"

    clip = js(ctx, "document.querySelector('#tutorial-backdrop').style.clipPath")
    assert clip =~ "polygon", "backdrop has no spotlight hole: #{inspect(clip)}"
    ctx
  end

  describe "tutorial" do
    test "auto-starts for a user who has not seen it, centred welcome card", ctx do
      seen!(false)

      ctx
      |> visit_page(DashboardPage)
      |> assert_selector("#tutorial-card")
      |> assert_text("#tutorial-progress", "Step 1 of 7")

      card = rect(ctx, "#tutorial-card")
      {vw, vh} = viewport(ctx)
      assert_in_delta card["x"] + card["w"] / 2, vw / 2, 2
      assert_in_delta card["y"] + card["h"] / 2, vh / 2, 2

      assert js(ctx, "getComputedStyle(document.querySelector('#tutorial-backdrop')).position") ==
               "fixed"
    end

    test "does not start for a user who has seen it", ctx do
      seen!(true)

      ctx
      |> visit_page(DashboardPage)
      |> assert_selector("#this-month-card")
      |> refute_selector("#tutorial-card")
    end

    test "Next walks every step, highlighting its target; Back returns; Finish persists", ctx do
      seen!(false)

      ctx = visit_page(ctx, DashboardPage) |> assert_selector("#tutorial-card")

      targets = [
        "#add-debt-button",
        "#debt-list",
        "#budget-input",
        "#chart-type-switcher",
        "#strategy-switcher",
        "#settings-button"
      ]

      for {target, i} <- Enum.with_index(targets, 2) do
        ctx
        |> click("#tutorial-next")
        |> assert_text("#tutorial-progress", "Step #{i} of 7")
        |> assert_sane_geometry(target)
      end

      # step 5 switches to comparison, 6 to simulation (strategy switcher visible)
      assert_selector(ctx, "#strategy-switcher")
      assert_text(ctx, "#tutorial-next", "Finish")

      # Back goes to step 6 again
      ctx
      |> click("#tutorial-back")
      |> assert_text("#tutorial-progress", "Step 6 of 7")
      |> assert_sane_geometry("#strategy-switcher")
      |> click("#tutorial-next")
      |> assert_text("#tutorial-progress", "Step 7 of 7")

      refute tutorial_seen?()
      click(ctx, "#tutorial-next")
      refute_selector(ctx, "#tutorial-card")
      wait_until(&tutorial_seen?/0)
    end

    test "steps 5 and 6 switch the chart type", ctx do
      seen!(false)

      ctx = visit_page(ctx, DashboardPage) |> assert_selector("#tutorial-card")

      # The backdrop swallows real clicks, so pick another chart from JS.
      js(ctx, "document.querySelector('#chart-type-monthly_payments').click()")

      wait_js(
        ctx,
        "document.querySelector('#chart-type-monthly_payments').className.includes('btn-primary')"
      )

      for _ <- 1..4, do: click(ctx, "#tutorial-next")
      assert_text(ctx, "#tutorial-progress", "Step 5 of 7")

      wait_js(
        ctx,
        "document.querySelector('#chart-type-comparison').className.includes('btn-primary')"
      )

      click(ctx, "#tutorial-next")
      assert_text(ctx, "#tutorial-progress", "Step 6 of 7")

      wait_js(
        ctx,
        "document.querySelector('#chart-type-simulation').className.includes('btn-primary')"
      )

      assert_selector(ctx, "#strategy-switcher")
    end

    test "Skip finishes and persists tutorial_seen", ctx do
      seen!(false)

      ctx
      |> visit_page(DashboardPage)
      |> assert_selector("#tutorial-card")
      |> click("#tutorial-next")
      |> assert_text("#tutorial-progress", "Step 2 of 7")
      |> click("#tutorial-skip")
      |> refute_selector("#tutorial-card")

      wait_until(&tutorial_seen?/0)

      # reload: does not auto-start again
      visit_page(ctx, DashboardPage)
      assert_selector(ctx, "#this-month-card")
      refute_selector(ctx, "#tutorial-card")
    end

    test "the card stays on screen at a 375px viewport on every step", ctx do
      seen!(false)

      ctx =
        set_viewport(ctx, 375, 700)
        |> visit_page(DashboardPage)
        |> assert_selector("#tutorial-card")

      refute h_overflow?(ctx)

      # welcome card fits
      card = rect(ctx, "#tutorial-card")
      assert card["x"] >= 0 and card["r"] <= 376, inspect(card)

      for target <- [
            "#add-debt-button",
            "#debt-list",
            "#budget-input",
            "#chart-type-switcher",
            "#strategy-switcher",
            "#settings-button"
          ] do
        click(ctx, "#tutorial-next")

        wait_js(
          ctx,
          "document.querySelector('#tutorial-card')?.getAttribute('data-target') === #{JSON.encode!(target)}"
        )

        Process.sleep(300)
        card = rect(ctx, "#tutorial-card")
        {vw, vh} = viewport(ctx)
        assert card["x"] >= 0 and card["r"] <= vw + 1, "#{target}: #{inspect(card)}"
        assert card["y"] >= 0 and card["b"] <= vh + 1, "#{target}: #{inspect(card)}"
        # Next stays reachable
        nxt = rect(ctx, "#tutorial-next")
        assert nxt["r"] <= vw + 1 and nxt["b"] <= vh + 1
      end
    end
  end

  describe "footer" do
    setup do
      seen!(true)
      :ok
    end

    test "renders links and the donate modal opens/closes by button, backdrop, Escape", ctx do
      ctx
      |> visit_page(DashboardPage)
      |> assert_selector("#app-footer")
      |> assert_selector("#donate-link")
      |> refute_selector("#donate-modal")
      |> click("#donate-link")
      |> assert_selector("#donate-modal")
      |> assert_selector("#donate-liberapay")
      |> click("#donate-modal-close")
      |> refute_selector("#donate-modal")
      # outside click (the dim area, not the card)
      |> click("#donate-link")
      |> assert_selector("#donate-modal")
      |> click_at("#donate-modal", 5, 5)
      |> refute_selector("#donate-modal")
      # Escape
      |> click("#donate-link")
      |> assert_selector("#donate-modal")
      |> press("Escape")
      |> refute_selector("#donate-modal")
    end

    test "clicking inside the donate card does not close it", ctx do
      ctx
      |> visit_page(DashboardPage)
      |> click("#donate-link")
      |> assert_selector("#donate-modal")
      |> click("#donate-github-sponsors")

      Process.sleep(300)
      assert_selector(ctx, "#donate-modal")
    end

    test "mobile: footer wraps without overflow and donate modal fits", ctx do
      ctx =
        set_viewport(ctx, 375, 700) |> visit_page(DashboardPage) |> assert_selector("#app-footer")

      refute h_overflow?(ctx)
      footer = rect(ctx, "#app-footer")
      assert footer["x"] >= 0 and footer["r"] <= 376
      assert footer["h"] >= 30

      # every footer link is inside the viewport
      for sel <- ["#donate-link"] do
        r = rect(ctx, sel)
        assert r["x"] >= 0 and r["r"] <= 376, "#{sel} #{inspect(r)}"
      end

      click(ctx, "#donate-link")
      assert_selector(ctx, "#donate-modal")
      card = rect(ctx, "#donate-modal > div:nth-child(2)")
      assert card["x"] >= 0 and card["r"] <= 376, inspect(card)
      assert card["y"] >= 0 and card["b"] <= 701, inspect(card)
    end
  end

  defp wait_until(fun, tries \\ 50) do
    cond do
      fun.() ->
        :ok

      tries == 0 ->
        flunk("condition never became true")

      true ->
        Process.sleep(100)
        wait_until(fun, tries - 1)
    end
  end
end
