defmodule DebtReliefTrackerWeb.Holo.ResponsiveBrowserTest do
  # Responsiveness of every /app screen at phone (375), tablet (768) and
  # desktop (1280) widths, against a workspace with long names, huge amounts,
  # a non-USD currency and many log entries. Each screen is checked for
  # horizontal page overflow, reachable modal controls, tap-target height
  # (phone), a non-empty chart and clipped stat numbers. Failures are
  # collected per screen so one run reports every problem.
  #
  # At 375px a screenshot of each screen is saved to $RESPONSIVE_SHOTS_DIR
  # (default: tmp/responsive-shots).
  use DebtReliefTracker.BrowserCase

  import DebtReliefTracker.BrowserExtras

  alias DebtReliefTracker.BrowserCase.Driver
  alias DebtReliefTracker.{Accounts, Debts, Payments, Settings}
  alias DebtReliefTrackerWeb.Holo.DashboardPage

  @moduletag timeout: 300_000

  @viewports [{"phone", 375, 812}, {"tablet", 768, 1024}, {"desktop", 1280, 800}]

  @long_name "Extraordinarily Long Named Revolving Credit Account With Rewards"

  # Returns a list of problem strings for the current page. `modal` is the
  # selector of an open modal root (or nil for the bare dashboard).
  @check_js """
  (modalSel, phone) => {
    const problems = [];
    const vw = window.innerWidth, vh = window.innerHeight;
    const desc = (e) => e.tagName.toLowerCase() + (e.id ? "#" + e.id : "") +
      (typeof e.className === "string" && e.className ? "." + e.className.trim().split(/\\s+/).slice(0, 4).join(".") : "");
    const visible = (e) => { const r = e.getBoundingClientRect(); const s = getComputedStyle(e);
      return r.width > 0 && r.height > 0 && s.visibility !== "hidden" && s.display !== "none"; };
    const clippedByAncestor = (e) => {
      for (let a = e.parentElement; a && a !== document.body; a = a.parentElement) {
        const s = getComputedStyle(a);
        if (/(auto|scroll|hidden|clip)/.test(s.overflowX)) {
          const r = a.getBoundingClientRect();
          if (r.right <= vw + 1 && r.left >= -1) return true;
        }
      }
      return false;
    };

    // (1) horizontal page overflow, naming the widest offender
    const de = document.documentElement;
    if (de.scrollWidth > vw) {
      let worst = null;
      for (const e of document.querySelectorAll("body *")) {
        if (!visible(e) || clippedByAncestor(e)) continue;
        const r = e.getBoundingClientRect();
        if (r.right > vw + 1 && (!worst || r.right > worst.r)) worst = {e, r: r.right};
      }
      problems.push("page overflows: scrollWidth " + de.scrollWidth + " > " + vw +
        (worst ? "; widest " + desc(worst.e) + " right=" + Math.round(worst.r) : ""));
    }

    // (5) text clipped by overflow:hidden (ellipsis truncation is deliberate)
    const clipSel = modalSel ? modalSel + " *" : "#summary-stats *, #this-month-card *, #debt-list *";
    for (const e of document.querySelectorAll(clipSel)) {
      if (!visible(e)) continue;
      const s = getComputedStyle(e);
      if (/(hidden|clip)/.test(s.overflowX) && s.textOverflow !== "ellipsis" &&
          e.scrollWidth > e.clientWidth + 1 && !/^(svg|canvas|input|textarea|select)$/i.test(e.tagName))
        problems.push("text clipped: " + desc(e) + " scrollWidth " + e.scrollWidth + " > " + e.clientWidth);
    }
    if (!modalSel) for (const e of document.querySelectorAll("#summary-stats .stat, #summary-stats .stat-value")) {
      if (e.scrollWidth > e.clientWidth + 1)
        problems.push("stat clipped: " + desc(e) + " scrollWidth " + e.scrollWidth + " > " + e.clientWidth);
      const r = e.getBoundingClientRect();
      if (r.right > vw + 1 || r.left < -1) problems.push("stat outside viewport: " + desc(e));
    }

    // (2) modal: dialog fits the viewport and scrolls itself; controls reachable
    if (modalSel) {
      const root = document.querySelector(modalSel);
      if (!root) { problems.push("modal " + modalSel + " missing"); return problems; }
      const box = [root, ...root.querySelectorAll("*")].find((e) =>
        /(auto|scroll)/.test(getComputedStyle(e).overflowY)) ;
      if (!box) problems.push("modal has no scrolling container");
      else {
        const r = box.getBoundingClientRect();
        if (r.left < -1 || r.right > vw + 1 || r.top < -1 || r.bottom > vh + 1)
          problems.push("dialog outside viewport: " + JSON.stringify([r.left, r.top, r.right, r.bottom].map(Math.round)));
        if (box.scrollWidth > box.clientWidth + 1)
          problems.push("dialog scrolls horizontally: " + box.scrollWidth + " > " + box.clientWidth);
      }
      const before = window.scrollY;
      for (const b of root.querySelectorAll("button, a[href], input[type=submit]")) {
        if (!visible(b)) continue;
        b.scrollIntoView({block: "nearest", inline: "nearest"});
        const r = b.getBoundingClientRect();
        if (r.left < -1 || r.right > vw + 1 || r.top < -1 || r.bottom > vh + 1)
          problems.push("unreachable control " + desc(b) + " " + JSON.stringify([r.left, r.top, r.right, r.bottom].map(Math.round)));
      }
      if (window.scrollY !== before) problems.push("page behind the modal scrolled");
      if (box) box.scrollTop = 0;
    }

    // (3) tap targets (phone): primary buttons and modal close controls
    if (phone) {
      const scope = modalSel ? modalSel + " " : "";
      for (const b of document.querySelectorAll(scope + ".btn-primary, " + scope + "[id$=close], " + scope + "[id$=cancel]")) {
        if (!visible(b)) continue;
        const r = b.getBoundingClientRect();
        if (r.height < 31.5) problems.push("tap target too short: " + desc(b) + " h=" + r.height);
      }
    }
    return problems;
  }
  """

  setup do
    workspace = Accounts.ensure_default_workspace!()
    user = Accounts.get_default_user!()
    {:ok, _} = Accounts.set_tutorial_seen(user, true)
    {:ok, _} = Settings.update_settings(Settings.get_settings!(workspace), %{"currency" => "EUR"})

    {:ok, big} =
      Debts.create_debt(workspace, nil, %{
        "name" => @long_name,
        "type" => "revolving",
        "balance" => "12345678.90",
        "apr" => "24.99",
        "minimum_payment_floor" => "35.00",
        "minimum_payment_rate" => "0.02",
        "credit_limit" => "20000000.00"
      })

    {:ok, loan} =
      Debts.create_debt(workspace, nil, %{
        "name" => "Installment loan with a very long descriptive name for the car",
        "type" => "installment",
        "balance" => "98765432.10",
        "apr" => "6.5",
        "fixed_payment" => "1250000.00"
      })

    for n <- 1..4 do
      {:ok, _} =
        Debts.create_debt(workspace, nil, %{
          "name" => "Card number #{n}",
          "type" => "revolving",
          "balance" => "#{n}500.00",
          "apr" => "19.9",
          "minimum_payment_floor" => "25.00",
          "minimum_payment_rate" => "0.02"
        })
    end

    {:ok, old} =
      Debts.create_debt(workspace, nil, %{
        "name" => "Paid off personal loan",
        "type" => "installment",
        "balance" => "100.00",
        "apr" => "5",
        "fixed_payment" => "100.00"
      })

    {:ok, _} = Debts.mark_paid_off(workspace, nil, old)

    for i <- 1..30 do
      {:ok, _} =
        Payments.log_payment(workspace, nil, if(rem(i, 2) == 0, do: big, else: loan), %{
          "amount" => "#{i}00.00",
          "paid_on" => Date.to_iso8601(Date.add(Date.utc_today(), -i))
        })
    end

    {:ok, _} =
      Settings.add_manual_retirement_profile(workspace, %{
        "name" => "A Person With A Considerably Long Display Name For Wrapping",
        "current_age" => "35",
        "retirement_age" => "65",
        "current_retirement_savings" => "12345678.90",
        "monthly_retirement_contribution" => "500",
        "monthly_gross_income" => "6000",
        "post_debt_investment_pct" => "15",
        "expected_annual_return_pct" => "7"
      })

    {:ok, workspace: workspace, user: user}
  end

  for {label, w, h} <- @viewports do
    describe "#{label} #{w}x#{h}" do
      @describetag vp: {label, w, h}

      test "dashboard and every modal", ctx do
        {label, w, h} = ctx.vp

        ctx =
          set_viewport(ctx, w, h) |> visit_page(DashboardPage) |> assert_selector("#plan-chart")

        shots = new_shots(w)

        screen(ctx, shots, label, "dashboard", nil, w)
        chart_checks(ctx, label)

        # chart-type picker + strategy switcher usable
        if w < 1024 do
          for t <- ["monthly_payments", "comparison", "simulation"] do
            ctx |> select_option("#chart-type-select", t)
            Process.sleep(300)
            chart_checks(ctx, label <> "/" <> t)
          end

          assert_usable(ctx, ["#chart-type-select", "#strategy-select"], label)
        else
          assert_usable(ctx, ["#chart-type-switcher"], label)
          click(ctx, "#chart-type-simulation")
          assert_selector(ctx, "#strategy-switcher")
          assert_usable(ctx, ["#strategy-switcher"], label)
        end

        # debt list (collapsed on phones)
        if w < 640, do: click(ctx, "#debt-list-toggle")
        assert_selector(ctx, "#debt-list")
        screen(ctx, shots, label, "dashboard-debt-list", nil, w)

        modal(
          ctx,
          shots,
          label,
          w,
          "add-debt",
          "#add-debt-button",
          "#debt-form-modal",
          "#debt-form-cancel"
        )

        # installment fields visible
        ctx |> click("#add-debt-button") |> assert_selector("#debt-form-modal")
        select_option(ctx, "#debt-type", "installment")
        Process.sleep(200)
        screen(ctx, shots, label, "add-debt-installment", "#debt-form-modal", w)
        click(ctx, "#debt-form-cancel")
        refute_selector(ctx, "#debt-form-modal")

        edit_id = js(ctx, "document.querySelector('[id^=edit-debt-]').id")

        modal(
          ctx,
          shots,
          label,
          w,
          "edit-debt",
          "##{edit_id}",
          "#debt-form-modal",
          "#debt-form-cancel"
        )

        pay_id = js(ctx, "document.querySelector('[id^=log-payment-]').id")

        modal(
          ctx,
          shots,
          label,
          w,
          "log-payment",
          "##{pay_id}",
          "#payment-modal",
          "#payment-cancel"
        )

        modal(
          ctx,
          shots,
          label,
          w,
          "log-all-balances",
          "#log-all-balances-button",
          "#log-all-balances-modal",
          "#log-all-balances-cancel"
        )

        modal(
          ctx,
          shots,
          label,
          w,
          "activity-log",
          "#activity-log-button",
          "#activity-log-modal",
          "#activity-log-close"
        )

        modal(
          ctx,
          shots,
          label,
          w,
          "settings",
          "#settings-button",
          "#settings-modal",
          "#settings-cancel"
        )

        # retirement: roster (with a profile), then the add form
        ctx |> click("#settings-button") |> assert_selector("#settings-modal")
        ctx |> click("#open-retirement") |> assert_selector("#retirement-modal")
        screen(ctx, shots, label, "retirement-roster", "#retirement-modal", w)
        click(ctx, "#open-add-retirement-profile")
        assert_selector(ctx, "#retirement-profile-form")
        screen(ctx, shots, label, "retirement-form", "#retirement-modal", w)
        click(ctx, "#retirement-source-manual")
        screen(ctx, shots, label, "retirement-form-manual", "#retirement-modal", w)
        press(ctx, "Escape")
        press(ctx, "Escape")
        refute_selector(ctx, "#retirement-modal")

        modal(
          ctx,
          shots,
          label,
          w,
          "donate",
          "#donate-link",
          "#donate-modal",
          "#donate-modal-close"
        )

        report!()
      end

      test "retirement onboarding (no profile yet)", ctx do
        {label, w, h} = ctx.vp

        :ok =
          Enum.each(
            Settings.list_retirement_profiles(ctx.workspace),
            &Settings.delete_retirement_profile/1
          )

        ctx =
          set_viewport(ctx, w, h)
          |> visit_page(DashboardPage)
          |> assert_selector("#retirement-onboarding-banner")

        shots = new_shots(w)
        screen(ctx, shots, label, "retirement-banner", nil, w)

        modal(
          ctx,
          shots,
          label,
          w,
          "retirement-onboarding",
          "#open-retirement-onboarding",
          "#retirement-modal",
          "#close-retirement-modal"
        )

        report!()
      end

      test "empty workspace dashboard", ctx do
        {label, w, h} = ctx.vp
        for d <- Debts.list_debts(ctx.workspace), do: Debts.delete_debt(ctx.workspace, nil, d)

        ctx =
          set_viewport(ctx, w, h)
          |> visit_page(DashboardPage)
          |> assert_selector("#summary-stats")

        shots = new_shots(w)
        screen(ctx, shots, label, "dashboard-empty", nil, w)
        report!()
      end

      test "tutorial on every step", ctx do
        {label, w, h} = ctx.vp
        {:ok, _} = Accounts.set_tutorial_seen(Accounts.get_default_user!(), false)

        ctx =
          set_viewport(ctx, w, h)
          |> visit_page(DashboardPage)
          |> assert_selector("#tutorial-card")

        shots = new_shots(w)

        for step <- 1..7 do
          assert_text(ctx, "#tutorial-progress", "Step #{step} of 7")
          Process.sleep(350)
          screen(ctx, shots, label, "tutorial-step-#{step}", nil, w)

          {vw, vh} = viewport(ctx)
          card = rect(ctx, "#tutorial-card")

          unless card["x"] >= 0 and card["r"] <= vw + 1 and card["y"] >= 0 and card["b"] <= vh + 1,
            do: add_problem("#{label} tutorial step #{step}: card off screen #{inspect(card)}")

          nxt = rect(ctx, "#tutorial-next")

          unless nxt["r"] <= vw + 1 and nxt["b"] <= vh + 1 and nxt["x"] >= 0 and nxt["y"] >= 0,
            do:
              add_problem(
                "#{label} tutorial step #{step}: next button unreachable #{inspect(nxt)}"
              )

          if w < 640 and nxt["h"] < 31.5,
            do: add_problem("#{label} tutorial step #{step}: next button #{nxt["h"]}px tall")

          if step < 7, do: click(ctx, "#tutorial-next")
        end

        report!()
      end
    end
  end

  describe "settings with sharing (OIDC mode)" do
    setup do
      Application.put_env(:debt_relief_tracker, :oidc,
        issuer: "http://127.0.0.1:1",
        client_id: "test-client",
        client_secret: "test-secret"
      )

      Application.put_env(:swoosh, :shared_test_process, self())

      on_exit(fn ->
        Application.put_env(:debt_relief_tracker, :oidc, nil)
        Application.delete_env(:swoosh, :shared_test_process)
      end)

      owner =
        Accounts.get_or_create_user_from_oidc!(%{
          "sub" => "resp-owner",
          "email" => "a.very.long.email.address.for.the.owner@example-long-domain.com",
          "name" => "Owner With A Very Long Display Name Indeed"
        })

      {:ok, _} = Accounts.set_tutorial_seen(owner, true)
      ws = Accounts.current_workspace_for_user(owner)

      {:ok, _} =
        Debts.create_debt(ws, owner, %{
          "name" => @long_name,
          "type" => "revolving",
          "balance" => "12345678.90",
          "apr" => "24.99",
          "minimum_payment_floor" => "35.00",
          "minimum_payment_rate" => "0.02"
        })

      friend =
        Accounts.get_or_create_user_from_oidc!(%{
          "sub" => "resp-friend",
          "email" => "friend.with.a.really.long.address@example-long-domain.com",
          "name" => "Friend With A Really Long Display Name"
        })

      {:ok, _} = Accounts.share_workspace_with_email(ws, friend.email, owner)

      {:ok, _} =
        Accounts.share_workspace_with_email(ws, "invitee.pending.long.address@example.org", owner)

      {:ok, owner: owner}
    end

    for {label, w, h} <- @viewports do
      test "settings + header at #{label}", %{owner: owner} = ctx do
        {label, w, h} = {unquote(label), unquote(w), unquote(h)}

        ctx =
          ctx
          |> sign_in(owner)
          |> set_viewport(w, h)
          |> visit_page(DashboardPage)
          |> assert_selector("#user-menu")

        shots = new_shots(w)
        screen(ctx, shots, label, "oidc-dashboard", nil, w)

        modal(
          ctx,
          shots,
          label,
          w,
          "oidc-settings",
          "#settings-button",
          "#settings-modal",
          "#settings-cancel"
        )

        report!()
      end
    end
  end

  # --- helpers --------------------------------------------------------------

  defp new_shots(w) do
    dir = System.get_env("RESPONSIVE_SHOTS_DIR") || Path.expand("tmp/responsive-shots")
    File.mkdir_p!(dir)
    if w == 375, do: dir, else: nil
  end

  defp add_problem(msg), do: Process.put(:problems, [msg | Process.get(:problems, [])])

  defp report! do
    problems = Process.get(:problems, []) |> Enum.reverse() |> Enum.uniq()
    Process.delete(:problems)
    assert problems == [], "Responsiveness problems:\n  - " <> Enum.join(problems, "\n  - ")
  end

  # Opens a modal, checks and screenshots it, closes it with its cancel/close button.
  defp modal(ctx, shots, label, w, name, opener, modal_sel, closer) do
    click(ctx, opener)
    assert_selector(ctx, modal_sel)
    Process.sleep(250)
    screen(ctx, shots, label, name, modal_sel, w)
    click(ctx, closer)
    refute_selector(ctx, modal_sel)
  end

  defp screen(ctx, shots, label, name, modal_sel, w) do
    problems = js(ctx, "(#{@check_js})(#{JSON.encode!(modal_sel)}, #{w < 640})")
    for p <- problems, do: add_problem("#{label} #{name}: #{p}")

    if shots do
      Driver.call(ctx.driver, "screenshot", %{
        path: Path.join(shots, "#{name}-#{w}.png"),
        fullPage: is_nil(modal_sel)
      })
    end

    ctx
  end

  defp chart_checks(ctx, label) do
    size =
      js(ctx, """
      (() => { const c = document.querySelector('#plan-chart canvas, #plan-chart svg');
        if (!c) return null; const r = c.getBoundingClientRect(); return {w: r.width, h: r.height,
        panel: document.querySelector('#plan-chart-panel').getBoundingClientRect().width}; })()
      """)

    cond do
      size == nil ->
        add_problem("#{label}: chart has no canvas")

      size["w"] < 100 or size["h"] < 100 ->
        add_problem("#{label}: chart too small #{inspect(size)}")

      true ->
        :ok
    end
  end

  # The pickers exist, are visible and fit the viewport.
  defp assert_usable(ctx, selectors, label) do
    {vw, _} = viewport(ctx)

    for sel <- selectors do
      r = rect(ctx, sel)

      cond do
        r == nil ->
          add_problem("#{label}: #{sel} missing")

        r["w"] == 0 ->
          add_problem("#{label}: #{sel} hidden")

        r["x"] < 0 or r["r"] > vw + 1 ->
          add_problem("#{label}: #{sel} outside viewport #{inspect(r)}")

        true ->
          :ok
      end
    end
  end
end
