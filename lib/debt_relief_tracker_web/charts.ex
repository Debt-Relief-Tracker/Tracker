defmodule DebtReliefTrackerWeb.Charts do
  @moduledoc """
  Builds Chart.js config maps for each payoff-plan chart type (docs/plan.md
  Phase 5). Pure data-shaping -- no Ecto, no rendering. `DashboardLive`
  pushes the result straight to the `PlanChart` JS hook via `push_event/3`;
  the hook just does `new Chart(canvas, config)`.
  """

  alias DebtReliefTracker.Debts.Calculations
  alias DebtReliefTracker.Planning

  @strategies [:cash_flow, :snowball, :avalanche]

  # A small fixed palette (not theme-adaptive yet -- see docs/roadmap.md).
  @palette [
    "#2563eb",
    "#f97316",
    "#16a34a",
    "#dc2626",
    "#9333ea",
    "#0891b2",
    "#ca8a04",
    "#db2777"
  ]

  @doc """
  Returns `{message, config}` for the given chart type: `message` is a
  user-facing string to show instead of a chart when there's nothing to
  plot yet (`nil` otherwise), `config` is a Chart.js config map ready to
  push to the client (`nil` when `message` is set).
  """
  def build(:comparison, _strategy, strategies, _debts, _budget, _lifetime_payments) do
    comparison_config(strategies)
  end

  def build(:simulation, strategy, strategies, debts, _budget, _lifetime_payments) do
    simulation_config(strategy, strategies, debts)
  end

  def build(:monthly_payments, strategy, strategies, debts, _budget, _lifetime_payments) do
    monthly_payments_config(strategy, strategies, debts)
  end

  def build(:freed_cashflow, strategy, _strategies, debts, budget, _lifetime_payments) do
    freed_cashflow_config(strategy, debts, budget)
  end

  def build(:interest_breakdown, _strategy, _strategies, _debts, _budget, lifetime_payments) do
    interest_breakdown_config(lifetime_payments)
  end

  # --- comparison: dual-axis bar chart (interest $ + months, per strategy) ---

  defp comparison_config(strategies) do
    if Enum.all?(strategies, &nothing_to_compare?/1) do
      {comparison_message(strategies), nil}
    else
      interest =
        Enum.map(@strategies, fn s ->
          with {:ok, result} <- strategies[s], do: Decimal.to_float(result.total_interest)
        end)

      months =
        Enum.map(@strategies, fn s ->
          with {:ok, result} <- strategies[s], do: result.total_months
        end)

      config = %{
        type: "bar",
        data: %{
          labels: Enum.map(@strategies, &strategy_label/1),
          datasets: [
            %{
              label: "Total interest ($)",
              data: interest,
              backgroundColor: color(1),
              yAxisID: "interest"
            },
            %{
              label: "Months to payoff",
              data: months,
              backgroundColor: color(0),
              yAxisID: "months"
            }
          ]
        },
        options: %{
          responsive: true,
          maintainAspectRatio: false,
          scales: %{
            interest: %{
              type: "linear",
              position: "left",
              beginAtZero: true,
              title: %{display: true, text: "Interest ($)"}
            },
            months: %{
              type: "linear",
              position: "right",
              beginAtZero: true,
              title: %{display: true, text: "Months"},
              grid: %{drawOnChartArea: false}
            }
          }
        }
      }

      {nil, config}
    end
  end

  defp nothing_to_compare?({_strategy, {:ok, %{total_months: 0}}}), do: true
  defp nothing_to_compare?({_strategy, {:error, _}}), do: true
  defp nothing_to_compare?(_), do: false

  defp comparison_message(strategies) do
    cond do
      Enum.any?(strategies, &match?({_, {:error, :insufficient_budget}}, &1)) ->
        "Your monthly budget doesn't cover minimum payments yet -- increase it above."

      Enum.any?(strategies, &match?({_, {:error, :did_not_converge}}, &1)) ->
        "This plan doesn't pay off within 50 years at this budget -- try raising it."

      true ->
        "Add a debt to compare payoff strategies."
    end
  end

  # --- simulation: one line per debt, plus a dashed total ---------------------

  defp simulation_config(strategy, strategies, debts) do
    case strategies[strategy] do
      {:ok, %{months: months}} when months != [] ->
        labels = Enum.map(months, &"Month #{&1.index}")
        debt_ids = months |> List.first() |> Map.fetch!(:lines) |> Enum.map(& &1.debt_id)

        debt_datasets =
          debt_ids
          |> Enum.with_index()
          |> Enum.map(fn {debt_id, i} ->
            %{
              label: debt_name(debts, debt_id),
              data: Enum.map(months, &ending_balance(&1, debt_id)),
              borderColor: color(i),
              backgroundColor: color(i),
              fill: false,
              tension: 0.15,
              pointRadius: 0
            }
          end)

        total_dataset = %{
          label: "Total",
          data: Enum.map(months, &total_ending_balance/1),
          borderColor: "#111827",
          borderDash: [6, 3],
          borderWidth: 2,
          fill: false,
          tension: 0.15,
          pointRadius: 0
        }

        config = %{
          type: "line",
          data: %{labels: labels, datasets: [total_dataset | debt_datasets]},
          options: %{
            responsive: true,
            maintainAspectRatio: false,
            interaction: %{mode: "index", intersect: false},
            scales: %{y: %{beginAtZero: true, title: %{display: true, text: "Balance ($)"}}}
          }
        }

        {nil, config}

      {:error, :insufficient_budget} ->
        {"Your monthly budget doesn't cover minimum payments yet -- increase it above.", nil}

      {:error, :did_not_converge} ->
        {"This plan doesn't pay off within 50 years at this budget -- try raising it.", nil}

      _ ->
        {"Add a debt to see the payoff simulation.", nil}
    end
  end

  defp ending_balance(month, debt_id) do
    month.lines
    |> Enum.find(&(&1.debt_id == debt_id))
    |> Map.fetch!(:ending_balance)
    |> Decimal.to_float()
  end

  defp total_ending_balance(month) do
    month.lines
    |> Enum.map(& &1.ending_balance)
    |> Enum.reduce(Decimal.new(0), &Decimal.add/2)
    |> Decimal.to_float()
  end

  # --- monthly payments: stacked area chart, one layer per debt ---------------

  defp monthly_payments_config(strategy, strategies, debts) do
    case strategies[strategy] do
      {:ok, %{months: months}} when months != [] ->
        labels = Enum.map(months, &"Month #{&1.index}")
        debt_ids = months |> List.first() |> Map.fetch!(:lines) |> Enum.map(& &1.debt_id)

        datasets =
          debt_ids
          |> Enum.with_index()
          |> Enum.map(fn {debt_id, i} ->
            %{
              label: debt_name(debts, debt_id),
              data: Enum.map(months, &payment_amount(&1, debt_id)),
              backgroundColor: color(i),
              borderColor: color(i),
              fill: true,
              tension: 0.15,
              pointRadius: 0
            }
          end)

        config = %{
          type: "line",
          data: %{labels: labels, datasets: datasets},
          options: %{
            responsive: true,
            maintainAspectRatio: false,
            interaction: %{mode: "index", intersect: false},
            scales: %{
              x: %{stacked: true},
              y: %{
                stacked: true,
                beginAtZero: true,
                title: %{display: true, text: "Payment ($)"}
              }
            }
          }
        }

        {nil, config}

      {:error, :insufficient_budget} ->
        {"Your monthly budget doesn't cover minimum payments yet -- increase it above.", nil}

      {:error, :did_not_converge} ->
        {"This plan doesn't pay off within 50 years at this budget -- try raising it.", nil}

      _ ->
        {"Add a debt to see monthly payments.", nil}
    end
  end

  defp payment_amount(month, debt_id) do
    month.lines
    |> Enum.find(&(&1.debt_id == debt_id))
    |> Map.fetch!(:payment)
    |> Decimal.to_float()
  end

  # --- freed cash flow: filled area chart --------------------------------------

  defp freed_cashflow_config(strategy, debts, budget) do
    case Planning.freed_cashflow_over_time(debts, budget, strategy) do
      {:ok, freed} when freed != [] ->
        config = %{
          type: "line",
          data: %{
            labels: Enum.map(freed, &"Month #{&1.index}"),
            datasets: [
              %{
                label: "Monthly payment freed",
                data: Enum.map(freed, &Decimal.to_float(&1.freed)),
                fill: true,
                backgroundColor: "rgba(37, 99, 235, 0.2)",
                borderColor: color(0),
                tension: 0.15,
                pointRadius: 0
              }
            ]
          },
          options: %{
            responsive: true,
            maintainAspectRatio: false,
            scales: %{
              y: %{beginAtZero: true, title: %{display: true, text: "Freed per month ($)"}}
            }
          }
        }

        {nil, config}

      _ ->
        {"Add a debt to see cash flow freed over time.", nil}
    end
  end

  # --- interest vs. principal: doughnut -----------------------------------------

  defp interest_breakdown_config(lifetime_payments) do
    principal =
      lifetime_payments
      |> Enum.map(&(&1.principal_portion || Decimal.new(0)))
      |> Enum.reduce(Decimal.new(0), &Decimal.add/2)

    interest = Calculations.lifetime_interest_paid(lifetime_payments)
    total = Decimal.add(principal, interest)

    if Decimal.equal?(total, 0) do
      {"Log a payment to start tracking this.", nil}
    else
      config = %{
        type: "doughnut",
        data: %{
          labels: ["Principal", "Interest"],
          datasets: [
            %{
              data: [Decimal.to_float(principal), Decimal.to_float(interest)],
              backgroundColor: [color(0), color(1)]
            }
          ]
        },
        options: %{
          responsive: true,
          maintainAspectRatio: false,
          plugins: %{legend: %{position: "bottom"}}
        }
      }

      {nil, config}
    end
  end

  defp color(i), do: Enum.at(@palette, rem(i, length(@palette)))

  @doc "The label shown for a debt in chart legends/tooltips (falls back to \"\" if not found)."
  def debt_name(debts, id), do: Enum.find_value(debts, "", &(&1.id == id && &1.name))

  @doc "The display label for a payoff strategy."
  def strategy_label(:cash_flow), do: "Cash flow"
  def strategy_label(:snowball), do: "Snowball"
  def strategy_label(:avalanche), do: "Avalanche"
end
