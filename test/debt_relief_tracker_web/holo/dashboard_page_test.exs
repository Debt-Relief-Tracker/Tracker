defmodule DebtReliefTrackerWeb.Holo.DashboardPageTest do
  use DebtReliefTrackerWeb.ConnCase

  alias DebtReliefTracker.{Accounts, Debts, Repo}
  alias DebtReliefTrackerWeb.Holo.DashboardPage

  setup do
    workspace = Accounts.ensure_default_workspace!()

    {:ok, _} =
      Debts.create_debt(workspace, nil, %{
        "name" => "Visa",
        "type" => "revolving",
        "balance" => "4500.00",
        "apr" => "24.99",
        "minimum_payment_floor" => "35.00",
        "minimum_payment_rate" => "0.02",
        "credit_limit" => "9000.00"
      })

    %{workspace: workspace}
  end

  defp render_doc(conn), do: conn |> get("/app") |> html_response(200) |> LazyHTML.from_document()

  defp text(doc, selector), do: doc |> LazyHTML.query(selector) |> LazyHTML.text()
  defp count(doc, selector), do: doc |> LazyHTML.query(selector) |> Enum.count()

  test "GET /app renders the dashboard shell and this-month card", %{conn: conn} do
    doc = render_doc(conn)

    assert count(doc, "#holo-dashboard") == 1
    assert text(doc, "#this-month-card") =~ "Visa"
  end

  describe "plan panel (server render)" do
    test "summary stat cards in order, with utilization once a limit is set", %{conn: conn} do
      doc = render_doc(conn)

      titles = doc |> LazyHTML.query("#summary-stats .stat-title") |> Enum.map(&LazyHTML.text/1)

      assert titles == [
               "Total Paid",
               "Interest Paid",
               "Debt Remaining",
               "Payoff Date",
               "Credit Utilization"
             ]

      assert text(doc, "#stat-debt-remaining .stat-value") =~ "$4,500.00"
      assert text(doc, "#stat-utilization .stat-value") =~ "50%"
      assert text(doc, "#stat-payoff-date .stat-desc") =~ "months left"
    end

    test "budget input (cents step), budget mode and the chart-type picker", %{conn: conn} do
      doc = render_doc(conn)

      [input] = doc |> LazyHTML.query("#budget-input") |> Enum.to_list()
      assert LazyHTML.attribute(input, "step") == ["0.01"]
      # Default budget: 105% of the $90 minimum, rounded up to a dollar.
      assert LazyHTML.attribute(input, "value") == ["95.00"]
      assert text(doc, "#budget-form label") =~ "Monthly budget"
      assert count(doc, "#budget-mode-total.btn-primary") == 1

      for type <-
            ~w(comparison simulation monthly_payments freed_cashflow interest_breakdown retirement_roadmap) do
        assert count(doc, "#chart-type-#{type}") == 1
      end

      assert count(doc, "#chart-type-comparison.btn-primary") == 1
      assert count(doc, "#chart-type-select") == 1
    end

    test "the comparison chart starts with the canvas container, not a message, and no strategy switcher",
         %{conn: conn} do
      doc = render_doc(conn)

      assert count(doc, "#plan-chart") == 1
      assert count(doc, "#plan-chart-message") == 0
      assert count(doc, "#strategy-switcher") == 0
    end

    test "an empty workspace says to add a debt", %{conn: conn, workspace: workspace} do
      workspace |> Debts.list_debts() |> Enum.each(&Repo.delete!/1)
      doc = render_doc(conn)

      assert text(doc, "#this-month-message") =~ "Add a debt to see your payoff plan."
      assert text(doc, "#plan-chart-message") =~ "Add a debt to compare payoff strategies."
      assert count(doc, "#plan-chart.hidden") == 1
    end

    test "a saved budget below the minimums is a budget message, never 'add a debt'",
         %{conn: conn, workspace: workspace} do
      settings = DebtReliefTracker.Settings.get_settings!(workspace)
      {:ok, _} = DebtReliefTracker.Settings.update_settings(settings, %{"monthly_budget" => "10"})

      doc = render_doc(conn)

      assert text(doc, "#this-month-message") =~ "budget doesn't cover minimum payments"
      assert text(doc, "#plan-chart-message") =~ "budget doesn't cover minimum payments"
      refute text(doc, "#plan-panel") =~ "Add a debt"
    end
  end

  describe "page actions" do
    test "snapshot and strategy changes tell the plan panel to recompute" do
      component = %Hologram.Component{state: %{modal: nil}}

      assert %{next_action: %{name: :plan_inputs_changed, target: "plan_panel"}} =
               DashboardPage.action(:snapshot_updated, %{snapshot: %{}}, component)

      assert %{
               state: %{strategy: :snowball},
               next_action: %{name: :plan_inputs_changed, target: "plan_panel"}
             } =
               DashboardPage.action(:select_strategy, %{strategy: :snowball}, component)
    end
  end

  test "GET /app renders the footer with the donate modal links and admin link", %{conn: conn} do
    doc = conn |> get("/app") |> html_response(200) |> LazyHTML.from_document()

    assert LazyHTML.query(doc, "#app-footer #donate-link") |> Enum.count() == 1
    assert LazyHTML.query(doc, "#donate-modal.hidden") |> Enum.count() == 1
    assert LazyHTML.query(doc, ~s(#donate-modal a#donate-liberapay[href="https://liberapay.com/DebtReliefTracker/"])) |> Enum.count() == 1
    assert LazyHTML.query(doc, ~s(#donate-modal a#donate-ko-fi[href="https://ko-fi.com/calonmerc"])) |> Enum.count() == 1
    assert LazyHTML.query(doc, "#donate-modal div#donate-github-sponsors") |> Enum.count() == 1
    assert LazyHTML.query(doc, "#donate-modal a#donate-github-sponsors") |> Enum.count() == 0
    # no-auth mode is fully trusted
    assert LazyHTML.query(doc, ~s(#app-footer a[href="/admin"])) |> Enum.count() == 1
  end

  test "GET /app does not server-render the tutorial overlay open", %{conn: conn} do
    doc = conn |> get("/app") |> html_response(200) |> LazyHTML.from_document()
    assert LazyHTML.query(doc, "#tutorial-overlay") |> Enum.count() == 1
    assert LazyHTML.query(doc, "#tutorial-card") |> Enum.count() == 0
  end
end
