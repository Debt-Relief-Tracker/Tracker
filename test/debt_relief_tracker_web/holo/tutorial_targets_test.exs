defmodule DebtReliefTrackerWeb.Holo.TutorialTargetsTest do
  # The tutorial spotlights elements by CSS selector, and those elements are
  # owned by other components. If one is renamed or dropped the overlay would
  # silently highlight nothing, so every step target must exist on a rendered
  # /app that has a debt.
  use DebtReliefTrackerWeb.ConnCase

  alias DebtReliefTracker.{Accounts, Debts}
  alias DebtReliefTracker.Engine.Charts
  alias DebtReliefTrackerWeb.Holo.Tutorial

  setup do
    workspace = Accounts.ensure_default_workspace!()

    {:ok, _} =
      Debts.create_debt(workspace, nil, %{
        "name" => "Visa",
        "type" => "revolving",
        "balance" => "4500.00",
        "apr" => "24.99",
        "minimum_payment_floor" => "35.00",
        "minimum_payment_rate" => "0.02"
      })

    :ok
  end

  # The strategy switcher is only rendered for strategy-dependent chart types
  # (as in the LiveView), and the dashboard opens on :comparison, so a static
  # render cannot contain it. The step switches the chart type first.
  @strategy_target "#strategy-switcher"

  test "every tutorial step target exists on the rendered dashboard", %{conn: conn} do
    doc = conn |> get("/app") |> html_response(200) |> LazyHTML.from_document()

    for %{target: target} <- Tutorial.steps(), target != nil, target != @strategy_target do
      assert LazyHTML.query(doc, target) |> Enum.count() >= 1,
             "tutorial target #{target} is missing from /app"
    end
  end

  test "the strategy step switches to a chart type that shows the strategy switcher" do
    step = Enum.find(Tutorial.steps(), &(&1.target == @strategy_target))

    assert step.chart_type
    assert Charts.strategy_dependent?(step.chart_type)
  end
end
