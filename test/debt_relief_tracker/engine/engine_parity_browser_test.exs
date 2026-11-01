defmodule DebtReliefTracker.Engine.EngineParityBrowserTest do
  @moduledoc """
  Closes the "engine matches in the browser" go/no-go item
  (docs/architecture/0007-e2ee.md): the REAL compiled `Engine.Planning`,
  `Calculations`, `Charts` and `Retirement` run inside Chromium (via the
  test-only `EngineParityPage`) on every scenario in
  `test/support/fixtures/*_scenarios.json`, and

    1. every integer they produce equals the server-side Engine's result
       EXACTLY (same digest text, compared string for string), and
    2. the browser's numbers satisfy the existing parity tolerances against
       the Decimal reference stored in the fixtures.

  Run with `mix test --include browser`.
  """
  use DebtReliefTracker.BrowserCase

  alias DebtReliefTracker.BrowserCase.Driver
  alias DebtReliefTracker.BrowserCase.EngineDigest
  alias DebtReliefTracker.BrowserCase.EngineInputs
  alias DebtReliefTracker.BrowserCase.EngineParityPage
  alias DebtReliefTracker.Engine.Convert
  alias DebtReliefTracker.Engine.Retirement

  @moduletag timeout: 900_000

  setup_all do
    System.put_env("BROWSER_TEST_TIMEOUT_MS", "30000")
    :ok
  end

  defp await_done(ctx, n, tries \\ 20) do
    ctx
    |> assert_text("#done", Integer.to_string(n))
    |> then(& &1)
  rescue
    error ->
      if tries > 0, do: await_done(ctx, n, tries - 1), else: reraise(error, __STACKTRACE__)
  end

  defp tok(text, name) do
    case Regex.run(~r/(?:^|;)#{name}=([^;]*)/, text) do
      [_, value] -> value
      nil -> nil
    end
  end

  defp ints(""), do: []
  defp ints(csv), do: csv |> String.split(",") |> Enum.map(&String.to_integer/1)

  test "the Engine in the browser equals the server Engine and the Decimal reference", ctx do
    inputs = EngineInputs.load()
    {raw_scenarios, raw_sets} = EngineInputs.raw()

    ctx = visit_page(ctx, EngineParityPage)
    t0 = System.monotonic_time(:millisecond)

    ctx =
      Enum.reduce(Enum.with_index(inputs.scenarios), ctx, fn {s, n}, ctx ->
        ctx |> click("#run-scenario-#{s.index}") |> await_done(n + 1)
      end)

    base = length(inputs.scenarios)

    ctx =
      Enum.reduce(inputs.jobs, ctx, fn job, ctx ->
        ctx |> click("#run-job-#{job.id}") |> await_done(base + job.id + 1)
      end)

    IO.puts(
      "[engine parity] all browser runs took #{System.monotonic_time(:millisecond) - t0} ms"
    )

    browser =
      eval(ctx, """
      Object.fromEntries(Array.from(document.querySelectorAll('pre[data-key]')).map(e => [e.dataset.key, e.textContent]))
      """)

    server =
      Map.new(
        Enum.flat_map(inputs.scenarios, fn s ->
          s |> EngineDigest.scenario() |> Enum.map(fn {k, v} -> {"sc#{s.index}/#{k}", v} end)
        end) ++
          Enum.flat_map(inputs.sets, fn set ->
            digest =
              Enum.reduce(
                set.cases,
                EngineDigest.retirement_base(set.profiles),
                &Map.merge(&2, EngineDigest.retirement_case(set.profiles, &1))
              )

            Enum.map(digest, fn {k, v} -> {"set#{set.index}/#{k}", v} end)
          end)
      )

    # 1. Exact equality, key for key.
    assert Enum.sort(Map.keys(browser)) == Enum.sort(Map.keys(server))

    mismatches = for {k, v} <- server, browser[k] != v, do: k

    assert mismatches == [],
           "browser result differs from server for: #{inspect(Enum.take(mismatches, 10))}"

    IO.puts(
      "[engine parity] #{map_size(server)} browser result blocks identical to the server Engine"
    )

    # 2. Tolerances against the Decimal reference (same bounds as parity_test.exs).
    for {raw, s} <- Enum.zip(raw_scenarios, inputs.scenarios),
        {name, exp} <- raw["expected"]["strategies"] do
      text = browser["sc#{s.index}/plan-#{name}"]
      sim = tok(text, "sim")
      label = "#{raw["name"]}/#{name}"

      assert Convert.to_cents(raw["expected"]["total_minimum_payments"]) ==
               String.to_integer(tok(text, "min_total")),
             label

      case exp["simulation"] do
        %{"status" => "error", "reason" => reason} ->
          assert sim == "error:#{reason}", label

        %{"status" => "ok"} = ref ->
          assert sim == "ok", label
          months = String.to_integer(tok(text, "months"))
          interest = String.to_integer(tok(text, "interest"))
          assert months == ref["total_months"], label

          assert abs(interest - Convert.to_cents(ref["total_interest"])) <=
                   months * length(raw["debts"]),
                 label

          assert tok(text, "first_target") ==
                   ref["first_month"]["target_debt_id"],
                 label
      end

      assert tok(text, "order") == Enum.join(exp["order"], ","), label

      if exp["windfall"]["months_saved"] do
        saved_months =
          Regex.run(~r/saved_months=(-?\d+)/, text) |> Enum.at(1) |> String.to_integer()

        saved_interest =
          Regex.run(~r/saved_interest=(-?\d+)/, text) |> Enum.at(1) |> String.to_integer()

        assert saved_months == exp["windfall"]["months_saved"], label

        assert abs(saved_interest - Convert.to_cents(exp["windfall"]["interest_saved"])) <=
                 length(raw["debts"]) * 100,
               label
      end
    end

    for {raw, set} <- Enum.zip(raw_sets, inputs.sets) do
      tolerance = retirement_tolerance(set.profiles)
      base = browser["set#{set.index}/ret-base"]
      assert String.to_integer(tok(base, "months")) == raw["months"], raw["name"]

      assert_within(
        ints(tok(base, "balances")),
        raw["baseline"]["balances"],
        tolerance,
        raw["name"]
      )

      assert ints(tok(base, "contributions")) ==
               Enum.map(raw["baseline"]["contributions"], &Convert.to_cents/1)

      for case_ <- raw["debt_cases"], {name, exp} <- case_["strategies"] do
        text = browser["set#{set.index}/ret-#{case_["debt_scenario"]}-#{name}"]
        label = "#{raw["name"]}/#{case_["debt_scenario"]}/#{name}"

        case exp do
          %{"status" => "error", "reason" => reason} ->
            assert tok(text, "status") == "error", label
            assert tok(text, "reason") == reason, label

          %{"status" => "ok"} ->
            assert tok(text, "status") == "ok", label
            assert_within(ints(tok(text, "balances")), exp["balances"], tolerance, label)

            assert_within(
              ints(tok(text, "contributions")),
              exp["contributions"],
              length(set.profiles),
              label
            )
        end
      end
    end

    assert Driver.call(ctx.driver, "errors", %{}) == []
  end

  defp retirement_tolerance(profiles) do
    months = Retirement.combined_months_to_retirement(profiles)

    Enum.sum(
      for profile <- profiles do
        monthly = 1 + profile.expected_annual_return_bp / 120_000
        ceil(Enum.sum(for k <- 0..(months - 1), do: :math.pow(monthly, k)))
      end
    )
  end

  defp assert_within(actual, expected, tolerance, label) do
    expected = Enum.map(expected, &Convert.to_cents/1)
    assert length(actual) == length(expected), "#{label}: series length"

    for {{a, e}, i} <- actual |> Enum.zip(expected) |> Enum.with_index() do
      assert abs(a - e) <= tolerance, "#{label}[#{i}]: #{a} vs #{e} exceeds #{tolerance} cents"
    end
  end
end
