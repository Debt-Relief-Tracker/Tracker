defmodule DebtReliefTrackerWeb.Holo.LiveViewVsHoloBrowserTest do
  @moduledoc """
  Loads the same seeded workspace in the LiveView dashboard (`/`, Decimal
  engine) and the Hologram dashboard (`/app`, integer engine) and compares
  the numbers a user can read: the stat cards, each debt's estimated balance
  and utilization, the this-month card and the monthly budget input -- for
  all three strategies.

  The only expected differences are whole cents from the integer engine
  rounding interest to a cent each month (docs/architecture/0007-e2ee.md).
  Every difference is printed in a table; anything above the bounds below
  fails the test. Run with `mix test --include browser`.
  """
  use DebtReliefTracker.BrowserCase

  alias DebtReliefTracker.{Accounts, Debts, Payments, Settings}
  alias DebtReliefTrackerWeb.Holo.DashboardPage

  @moduletag timeout: 600_000

  @strategies [{"cash_flow", "Cash flow"}, {"snowball", "Snowball"}, {"avalanche", "Avalanche"}]

  @scrape """
  (() => {
    const txt = (el) => (el ? el.textContent.replace(/\\s+/g, ' ').trim() : null);
    const stats = {};
    document.querySelectorAll('.stats .stat').forEach((s) => {
      stats[txt(s.querySelector('.stat-title'))] = {
        value: txt(s.querySelector('.stat-value')),
        desc: txt(s.querySelector('.stat-desc'))
      };
    });
    const debts = Array.from(document.querySelectorAll('#debt-list > li')).map((li) => ({
      name: txt(li.querySelector('span.font-medium')),
      balance: txt(li.querySelector('div.text-sm')),
      utilization:
        Array.from(li.querySelectorAll('div.text-xs')).map(txt).find((t) => t && t.includes('utilization')) || null
    }));
    const h2 = Array.from(document.querySelectorAll('h2')).find((h) => txt(h) === 'This month');
    const card = h2 ? h2.parentElement : null;
    const lines = card
      ? Array.from(card.querySelectorAll('.flex.flex-wrap.gap-4.text-sm > div')).map(txt)
      : [];
    const msgs = card ? Array.from(card.querySelectorAll(':scope > p')).map(txt) : [];
    const input = document.querySelector('#budget-input');
    return {
      stats, debts, lines, msgs,
      budget: input ? input.value : null,
      label: input ? txt(input.closest('form').querySelector('label')) : null
    };
  })()
  """

  # --- seeding -------------------------------------------------------------

  defp seed(opts \\ []) do
    workspace = Accounts.ensure_default_workspace!()
    {:ok, _} = Accounts.set_tutorial_seen(Accounts.get_default_user!(), true)
    today = Date.utc_today()

    debt = fn attrs ->
      {:ok, d} = Debts.create_debt(workspace, nil, attrs)
      d
    end

    visa =
      debt.(%{
        "name" => "Visa",
        "type" => "revolving",
        "balance" => "4500.00",
        "apr" => "24.99",
        "minimum_payment_floor" => "35.00",
        "minimum_payment_rate" => "0.02",
        "credit_limit" => "9000.00",
        "statement_balance" => "4400.00",
        "statement_date" => Date.to_iso8601(Date.add(today, -20))
      })

    debt.(%{
      "name" => "Store Card",
      "type" => "revolving",
      "balance" => "800.55",
      "apr" => "29.99",
      "minimum_payment_floor" => "25.00",
      "minimum_payment_rate" => "0.03",
      "credit_limit" => "1000.00"
    })

    debt.(%{
      "name" => "Gold Card",
      "type" => "revolving",
      "balance" => "2650.40",
      "apr" => "17.49",
      "minimum_payment_floor" => "30.00",
      "minimum_payment_rate" => "0.0225",
      "credit_limit" => "5000.00",
      "statement_balance" => "2600.00",
      "statement_date" => Date.to_iso8601(Date.add(today, -45))
    })

    debt.(%{
      "name" => "Car Loan",
      "type" => "installment",
      "balance" => "12000.00",
      "apr" => "6.5",
      "fixed_payment" => "310.00"
    })

    debt.(%{
      "name" => "Student Loan",
      "type" => "installment",
      "balance" => "18250.75",
      "apr" => "4.25",
      "fixed_payment" => "215.00"
    })

    debt.(%{
      "name" => "Excluded Loan",
      "type" => "installment",
      "balance" => "500.00",
      "apr" => "3.0",
      "fixed_payment" => "50.00",
      "exclude_from_plan" => true
    })

    old =
      debt.(%{
        "name" => "Old Card",
        "type" => "revolving",
        "balance" => "100.00",
        "apr" => "19.99",
        "minimum_payment_floor" => "25.00",
        "minimum_payment_rate" => "0.02",
        "credit_limit" => "2000.00"
      })

    {:ok, _} = Debts.mark_paid_off(workspace, nil, old)

    for {amount, days_ago} <- [{"300.00", 30}, {"150.25", 12}] do
      {:ok, _} =
        Payments.log_payment(workspace, nil, Debts.get_debt!(workspace, visa.id), %{
          "amount" => amount,
          "paid_on" => Date.to_iso8601(Date.add(today, -days_ago))
        })
    end

    setting = Settings.get_settings!(workspace)
    attrs = Map.new(Keyword.take(opts, [:monthly_budget, :budget_mode]))
    if attrs != %{}, do: {:ok, _} = Settings.update_settings(setting, attrs)
    workspace
  end

  # --- driving both UIs ----------------------------------------------------

  defp scrape(ctx), do: eval(ctx, @scrape)

  # Re-scrapes until three consecutive reads agree (Hologram re-plans in the
  # browser a moment after a click; LiveView patches immediately).
  defp settled(ctx, previous \\ nil, same \\ 0) do
    Process.sleep(500)
    current = scrape(ctx)

    cond do
      current == previous and same >= 2 -> current
      current == previous -> settled(ctx, current, same + 1)
      true -> settled(ctx, current, 0)
    end
  end

  defp select_strategy(ctx, label) do
    ctx
    |> click("#strategy-switcher button:text-is(\"#{label}\")")
    |> wait_for_expr(
      "(() => { const b = document.querySelector('#strategy-switcher .join button.btn-primary'); return !!b && b.textContent.trim() === '#{label}'; })()"
    )
  end

  defp liveview_numbers(ctx) do
    visit(ctx, "/")
    ctx = ctx |> assert_selector("#budget-input") |> assert_selector("#debt-list")
    first = settled(ctx)

    ctx = click(ctx, "button:text-is(\"Payoff simulation\")")
    ctx = assert_selector(ctx, "#strategy-switcher")

    Map.new(
      [{"__initial", first}] ++
        for {key, label} <- @strategies do
          ctx = select_strategy(ctx, label)
          {key, settled(ctx)}
        end
    )
  end

  defp holo_numbers(ctx) do
    ctx =
      visit_page(ctx, DashboardPage)
      |> assert_selector("#debt-list")
      |> assert_selector("#stat-total-paid")

    first = settled(ctx)

    ctx = click(ctx, "#chart-type-simulation") |> assert_selector("#strategy-switcher")

    Map.new(
      [{"__initial", first}] ++
        for {key, label} <- @strategies do
          ctx = select_strategy(ctx, label)
          {key, settled(ctx)}
        end
    )
  end

  # --- parsing & comparing -------------------------------------------------

  defp cents(nil), do: nil

  defp cents(text) do
    [digits] = Regex.run(~r/-?[\d,]+(?:\.\d+)?/, text)

    digits
    |> String.replace(",", "")
    |> Decimal.new()
    |> Decimal.mult(100)
    |> Decimal.to_integer()
  end

  @months ~w(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec)

  defp month_index("—"), do: nil

  defp month_index(text) do
    [mon, year] = String.split(text, " ")
    String.to_integer(year) * 12 + Enum.find_index(@months, &(&1 == mon))
  end

  defp left_months(nil), do: nil
  defp left_months(text), do: text |> String.split(" ") |> hd() |> String.to_integer()

  defp parse_line(text) do
    [_, name, amount | rest] = Regex.run(~r/^(.*?): pay (\S+)(?: (extra))?$/, text)
    {name, %{cents: cents(amount), extra: rest == ["extra"]}}
  end

  # Returns {rows, failures}: rows are {strategy, what, lv, holo, diff} for
  # every numeric comparison; failures are mismatches beyond the bound.
  defp compare(key, lv, holo, eligible) do
    stat = fn snap, title -> snap["stats"][title] end

    money = fn title, bound ->
      a = cents(stat.(lv, title)["value"])
      b = cents(stat.(holo, title)["value"])
      {{key, title, a, b, b - a}, abs(b - a) <= bound}
    end

    months_lv = left_months(stat.(lv, "Payoff Date")["desc"])
    months_holo = left_months(stat.(holo, "Payoff Date")["desc"])
    n = max(eligible, 1)
    bound_interest = max(months_lv || 0, months_holo || 0) * n

    stat_rows = [
      money.("Debt Remaining", n),
      money.("Interest Paid", bound_interest),
      money.("Total Paid", bound_interest + n)
    ]

    exact = fn what, a, b -> {{key, what, a, b, if(a == b, do: 0, else: :differs)}, a == b} end

    month_diff =
      (month_index(stat.(holo, "Payoff Date")["value"]) || 0) -
        (month_index(stat.(lv, "Payoff Date")["value"]) || 0)

    payoff_rows = [
      {{key, "Payoff months left", months_lv, months_holo, (months_holo || 0) - (months_lv || 0)},
       abs((months_holo || 0) - (months_lv || 0)) <= 1},
      {{key, "Payoff date (months apart)", stat.(lv, "Payoff Date")["value"],
        stat.(holo, "Payoff Date")["value"], month_diff}, abs(month_diff) <= 1},
      exact.(
        "Utilization stat",
        stat.(lv, "Credit Utilization"),
        stat.(holo, "Credit Utilization")
      )
    ]

    debt_rows =
      for lv_debt <- lv["debts"] do
        holo_debt = Enum.find(holo["debts"], &(&1["name"] == lv_debt["name"]))
        a = cents(lv_debt["balance"])
        b = holo_debt && cents(holo_debt["balance"])

        [
          {{key, "est. balance #{lv_debt["name"]}", a, b, b && b - a},
           b != nil and abs(b - a) <= 1},
          exact.(
            "utilization #{lv_debt["name"]}",
            lv_debt["utilization"],
            holo_debt && holo_debt["utilization"]
          )
        ]
      end
      |> List.flatten()

    lv_lines = Map.new(lv["lines"], &parse_line/1)
    holo_lines = Map.new(holo["lines"], &parse_line/1)

    line_rows =
      [
        exact.(
          "this-month debts paid",
          Enum.sort(Map.keys(lv_lines)),
          Enum.sort(Map.keys(holo_lines))
        ),
        exact.(
          "this-month target (extra)",
          for({name, %{extra: true}} <- lv_lines, do: name),
          for({name, %{extra: true}} <- holo_lines, do: name)
        )
      ] ++
        for {name, %{cents: a}} <- lv_lines, holo_lines[name] do
          b = holo_lines[name].cents
          {{key, "this-month pay #{name}", a, b, b - a}, abs(b - a) <= n}
        end

    msg_rows = [exact.("this-month message", lv["msgs"], holo["msgs"])]

    # Same amount to the cent; LiveView prints the raw Decimal ("1500",
    # "809.371000") and Hologram integer cents ("1500.00", "809.37").
    budget_cents = fn text ->
      text
      |> Decimal.new()
      |> Decimal.mult(100)
      |> Decimal.round(0, :half_up)
      |> Decimal.to_integer()
    end

    budget_rows = [
      exact.("budget input (cents)", budget_cents.(lv["budget"]), budget_cents.(holo["budget"])),
      exact.("budget label", lv["label"], holo["label"])
    ]

    all = stat_rows ++ payoff_rows ++ debt_rows ++ line_rows ++ msg_rows ++ budget_rows
    {Enum.map(all, &elem(&1, 0)), for({row, false} <- all, do: row)}
  end

  defp print_table(title, rows) do
    IO.puts("\n[LiveView vs Hologram] #{title}")
    IO.puts("strategy | quantity | LiveView | Hologram | diff")

    for {key, what, a, b, diff} <- rows, diff != 0 do
      IO.puts("#{key} | #{what} | #{inspect(a)} | #{inspect(b)} | #{inspect(diff)}")
    end

    zero = Enum.count(rows, fn {_, _, _, _, diff} -> diff == 0 end)
    IO.puts("(#{zero} of #{length(rows)} compared values identical)")
  end

  defp run_comparison(ctx, title, eligible) do
    lv = liveview_numbers(ctx)
    holo = holo_numbers(ctx)

    {rows, failures} =
      Enum.reduce(@strategies, {[], []}, fn {key, _label}, {rows, failures} ->
        {r, f} = compare(key, lv[key], holo[key], eligible)
        {rows ++ r, failures ++ f}
      end)

    # The page-load view (default strategy, comparison chart) must also agree.
    {r0, f0} = compare("initial(cash_flow)", lv["__initial"], holo["__initial"], eligible)
    rows = rows ++ r0
    failures = failures ++ f0

    print_table(title, rows)

    for {key, _label} <- @strategies do
      IO.puts(
        "[LiveView vs Hologram]   #{key}: payoff #{lv[key]["stats"]["Payoff Date"]["value"]} (#{lv[key]["stats"]["Payoff Date"]["desc"]}) in both; Total Paid #{lv[key]["stats"]["Total Paid"]["value"]} / #{holo[key]["stats"]["Total Paid"]["value"]}"
      )
    end

    max_cents =
      rows
      |> Enum.map(&elem(&1, 4))
      |> Enum.filter(&is_integer/1)
      |> Enum.map(&abs/1)
      |> Enum.max(fn -> 0 end)

    IO.puts("[LiveView vs Hologram] #{title}: max |diff| = #{max_cents} cents")

    assert failures == [], "differences beyond the documented rounding: #{inspect(failures)}"
    :ok
  end

  # Eligible debts in the plan: the five active, non-excluded ones.
  @eligible 5

  test "a saved budget: all numbers agree to the cent for every strategy", ctx do
    seed(monthly_budget: Decimal.new("1500"))
    run_comparison(ctx, "saved budget $1500, total mode", @eligible)
  end

  test "default budget (nothing saved) agrees", ctx do
    seed()
    run_comparison(ctx, "default budget", @eligible)
  end

  test "margin mode agrees", ctx do
    seed(monthly_budget: Decimal.new("1500"), budget_mode: :margin)
    run_comparison(ctx, "saved budget $1500, margin mode", @eligible)
  end
end
