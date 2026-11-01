defmodule DebtReliefTrackerWeb.Holo.PlanChartBrowserTest do
  # Real-browser check of the plan panel and Chart.js facade: serves the
  # test endpoint on a throwaway local port (test database, shared sandbox --
  # never the dev server or dev DB) and drives headless Chromium through
  # test/support/browser/plan_chart_check.mjs.
  #
  # Excluded by default; run with `mix test --include browser`. Needs Node
  # and a Chromium binary (BROWSER_CHROMIUM, else Playwright's cache).
  use DebtReliefTrackerWeb.ConnCase, async: false

  alias DebtReliefTracker.{Accounts, Debts, Settings}

  @moduletag :browser
  @moduletag timeout: 180_000

  @script Path.expand("../../support/browser/plan_chart_check.mjs", __DIR__)

  defp chromium do
    System.get_env("BROWSER_CHROMIUM") ||
      Path.wildcard(Path.expand("~/.cache/ms-playwright/chromium-*/chrome-linux/chrome"))
      |> List.last()
  end

  setup do
    workspace = Accounts.ensure_default_workspace!()

    for {name, balance, apr} <- [{"Visa", "4500.00", "24.99"}, {"Store card", "800.00", "29.99"}] do
      {:ok, _} =
        Debts.create_debt(workspace, nil, %{
          "name" => name,
          "type" => "revolving",
          "balance" => balance,
          "apr" => apr,
          "minimum_payment_floor" => "35.00",
          "minimum_payment_rate" => "0.02",
          "credit_limit" => "9000.00"
        })
    end

    port = 4500 + :rand.uniform(400)

    start_supervised!(
      {Bandit,
       plug: DebtReliefTrackerWeb.Endpoint, ip: {127, 0, 0, 1}, port: port, startup_log: false}
    )

    %{workspace: workspace, base_url: "http://127.0.0.1:#{port}"}
  end

  test "charts draw, switch, show messages, follow the theme, and the budget persists", %{
    base_url: base_url,
    workspace: workspace
  } do
    chromium = chromium()
    assert chromium && File.exists?(chromium), "no Chromium found; set BROWSER_CHROMIUM"

    shots = Path.join(System.tmp_dir!(), "plan-chart-shots")
    File.mkdir_p!(shots)

    {output, _status} =
      System.cmd("node", [@script, chromium, base_url, shots], stderr_to_stdout: true)

    report =
      case output |> String.split("\n", trim: true) |> List.last() |> Jason.decode() do
        {:ok, report} -> report
        {:error, _} -> flunk("browser script failed:\n#{output}")
      end

    IO.puts("\nbrowser report: #{inspect(report, pretty: true)}\nscreenshots: #{shots}")

    assert report["errors"] == []

    for {step, result} <- report["steps"], is_boolean(result) do
      assert result, "browser step #{step} failed"
    end

    assert Decimal.equal?(Settings.get_settings!(workspace).monthly_budget, Decimal.new("1000"))
  end
end
