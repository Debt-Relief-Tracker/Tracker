defmodule DebtReliefTracker.Engine.Charts do
  @moduledoc """
  Client-safe port of `DebtReliefTrackerWeb.Charts`: builds a Chart.js config
  map for each payoff-plan chart type from the integer engine's results.
  Pure and runs in the browser (Hologram) as well as in ExUnit -- no
  `Decimal`, floats, `Date` or regex (docs/holo-ui-conventions.md).

  Inputs are in engine units: `strategies` maps each strategy to an
  `Engine.Planning.simulate/4` result, `debts` are `Engine.FromSnapshot`
  maps (with `:name`), `budget` and payment portions are integer cents.

  Differences from the LiveView builder, all deliberate:

    * Plotted values are **dollar strings with exact cents** (`"1234.56"`)
      instead of floats. Chart.js reads primitive data with `+value`, so
      strings plot as numbers, and no amount is ever a float. (The only
      floats are the constant line `tension` style literals.)
    * Tick and tooltip formatting is declarative, so the JS facade
      (`assets/js/chart_facade.mjs`) stays free of app logic: a scale's
      `ticks.format` and a dataset's `valueFormat` are `Intl.NumberFormat`
      options, and a dataset's `afterLabels` are ready-made tooltip lines.
    * Every chart type tells "budget too low" and "never pays off" apart
      from "nothing to plot" -- the LiveView's freed-cash-flow chart still
      reported a budget error as "Add a debt" (the bug fixed for the
      comparison chart in 216bcc9; see `plan_message/2`).
    * Light/dark colors are resolved here (`theme_variants/1`) instead of
      being recolored by value in JS.

  Because the integer engine rounds interest to a cent each month, values
  can drift from the Decimal builder by under a cent per debt-month
  (docs/architecture/0007-e2ee.md).
  """

  alias DebtReliefTracker.Engine.Calculations
  alias DebtReliefTracker.Engine.Planning
  alias DebtReliefTracker.Engine.Retirement

  @strategies [:cash_flow, :snowball, :avalanche]
  @chart_types [
    :comparison,
    :simulation,
    :monthly_payments,
    :freed_cashflow,
    :interest_breakdown,
    :retirement_roadmap
  ]

  # Light-theme palette (same hex values as DebtReliefTrackerWeb.Charts) and
  # its dark counterpart, hue for hue (Tailwind 600 -> 400).
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
  @dark_palette [
    "#60a5fa",
    "#fb923c",
    "#4ade80",
    "#f87171",
    "#c084fc",
    "#22d3ee",
    "#facc15",
    "#f472b6"
  ]
  @total_line_color "#111827"
  @dark_total_line_color "#e5e7eb"
  @freed_cashflow_fill "rgba(37, 99, 235, 0.2)"
  @dark_freed_cashflow_fill "rgba(96, 165, 250, 0.25)"

  @insufficient_budget_message "Your monthly budget doesn't cover minimum payments yet -- increase it above."
  @did_not_converge_message "This plan doesn't pay off within 50 years at this budget -- try raising it."
  @no_retirement_profile_message "Set up a retirement profile for at least one person to see how debt strategies affect your household's nest egg."

  def strategies, do: @strategies
  def chart_types, do: @chart_types

  @doc "The display label for a payoff strategy."
  def strategy_label(:cash_flow), do: "Cash flow"
  def strategy_label(:snowball), do: "Snowball"
  def strategy_label(:avalanche), do: "Avalanche"

  @doc "The picker label for a chart type (same strings as `DashboardLive`)."
  def chart_label(:comparison), do: "Compare strategies"
  def chart_label(:simulation), do: "Payoff simulation"
  def chart_label(:monthly_payments), do: "Monthly payments"
  def chart_label(:freed_cashflow), do: "Cash flow freed"
  def chart_label(:interest_breakdown), do: "Interest vs. principal"
  def chart_label(:retirement_roadmap), do: "Retirement roadmap"

  @doc "Chart types whose plot depends on the selected strategy."
  def strategy_dependent?(chart_type),
    do: chart_type not in [:comparison, :interest_breakdown, :retirement_roadmap]

  @doc "The label shown for a debt in legends/tooltips (\"\" if not found)."
  def debt_name(debts, id), do: Enum.find_value(debts, "", &(&1.id == id && &1.name))

  @doc """
  The user-facing message for a plan that can't be charted, or `nil` when
  `result` is a non-empty plan. `empty_message` is only for "nothing to
  plan" (no eligible debts); budget errors always get their own message --
  never "add a debt" (see the moduledoc).
  """
  def plan_message({:ok, %{months: [_ | _]}}, _empty_message), do: nil
  def plan_message({:error, :insufficient_budget}, _empty), do: @insufficient_budget_message
  def plan_message({:error, :did_not_converge}, _empty), do: @did_not_converge_message
  def plan_message(_empty_or_missing, empty_message), do: empty_message

  @doc """
  Returns `{message, config}` for `chart_type`: `message` is a string to
  show instead of a chart when there's nothing to plot (`nil` otherwise),
  `config` a Chart.js config map (`nil` when `message` is set).

  Options: `:currency` (ISO code for money formatting, default `"USD"`).
  """
  def build(
        chart_type,
        strategy,
        strategies,
        debts,
        budget,
        payments,
        retirement_profiles,
        opts \\ []
      ) do
    currency = Keyword.get(opts, :currency) || "USD"

    case chart_type do
      :comparison ->
        comparison_config(strategies, currency)

      :simulation ->
        simulation_config(plan(strategies, strategy, debts, budget), debts, currency)

      :monthly_payments ->
        monthly_payments_config(plan(strategies, strategy, debts, budget), debts, currency)

      :freed_cashflow ->
        freed_cashflow_config(plan(strategies, strategy, debts, budget), debts, currency)

      :interest_breakdown ->
        interest_breakdown_config(payments, currency)

      :retirement_roadmap ->
        retirement_roadmap(retirement_profiles, debts, budget, currency)
    end
  end

  # The selected strategy's simulation, reusing the caller's when present.
  defp plan(strategies, strategy, debts, budget) do
    Map.get(strategies || %{}, strategy) || Planning.simulate(debts, budget, strategy)
  end

  # --- comparison: dual-axis bar chart (interest $ + months, per strategy) ---

  defp comparison_config(strategies, currency) do
    results = Enum.map(@strategies, &Map.get(strategies || %{}, &1))

    if Enum.all?(results, &nothing_to_compare?/1) do
      {comparison_message(results), nil}
    else
      interest = Enum.map(results, &ok_value(&1, fn r -> dollars(r.total_interest) end))
      months = Enum.map(results, &ok_value(&1, fn r -> r.total_months end))

      config = %{
        type: "bar",
        data: %{
          labels: Enum.map(@strategies, &strategy_label/1),
          datasets: [
            %{
              label: "Total interest ($)",
              data: interest,
              backgroundColor: color(1),
              yAxisID: "interest",
              valueFormat: money_format(currency)
            },
            %{
              label: "Months to payoff",
              data: months,
              backgroundColor: color(0),
              yAxisID: "months",
              valueFormat: months_format()
            }
          ]
        },
        options:
          base_options(%{
            scales: %{
              interest: %{
                type: "linear",
                position: "left",
                beginAtZero: true,
                title: %{display: true, text: "Interest ($)"},
                ticks: %{format: tick_money_format(currency)}
              },
              months: %{
                type: "linear",
                position: "right",
                beginAtZero: true,
                title: %{display: true, text: "Months"},
                grid: %{drawOnChartArea: false}
              }
            }
          })
      }

      {nil, config}
    end
  end

  defp nothing_to_compare?({:ok, %{total_months: 0}}), do: true
  defp nothing_to_compare?({:ok, _}), do: false
  defp nothing_to_compare?(_error_or_missing), do: true

  defp comparison_message(results) do
    cond do
      {:error, :insufficient_budget} in results -> @insufficient_budget_message
      {:error, :did_not_converge} in results -> @did_not_converge_message
      true -> "Add a debt to compare payoff strategies."
    end
  end

  defp ok_value({:ok, result}, fun), do: fun.(result)
  defp ok_value(_error_or_missing, _fun), do: nil

  # --- simulation: one line per debt, plus a dashed total ---------------------

  defp simulation_config(result, debts, currency) do
    case plan_message(result, "Add a debt to see the payoff simulation.") do
      nil ->
        {:ok, %{months: months}} = result

        debt_datasets =
          months
          |> debt_ids()
          |> Enum.with_index()
          |> Enum.map(fn {debt_id, i} ->
            %{
              label: debt_name(debts, debt_id),
              data: Enum.map(months, &dollars(line_value(&1, debt_id, :ending_balance))),
              borderColor: color(i),
              backgroundColor: color(i),
              fill: false,
              tension: 0.15,
              pointRadius: 0,
              valueFormat: money_format(currency)
            }
          end)

        total_dataset = %{
          label: "Total",
          data: Enum.map(months, &dollars(total_ending_balance(&1))),
          borderColor: @total_line_color,
          borderDash: [6, 3],
          borderWidth: 2,
          fill: false,
          tension: 0.15,
          pointRadius: 0,
          valueFormat: money_format(currency)
        }

        config = %{
          type: "line",
          data: %{labels: month_labels(months), datasets: [total_dataset | debt_datasets]},
          options:
            base_options(%{
              interaction: %{mode: "index", intersect: false},
              scales: %{
                y: %{
                  beginAtZero: true,
                  title: %{display: true, text: "Balance ($)"},
                  ticks: %{format: tick_money_format(currency)}
                }
              }
            })
        }

        {nil, config}

      message ->
        {message, nil}
    end
  end

  defp total_ending_balance(month), do: Enum.reduce(month.lines, 0, &(&1.ending_balance + &2))

  # --- monthly payments: stacked area chart, one layer per debt ---------------

  defp monthly_payments_config(result, debts, currency) do
    case plan_message(result, "Add a debt to see monthly payments.") do
      nil ->
        {:ok, %{months: months}} = result

        datasets =
          months
          |> debt_ids()
          |> Enum.with_index()
          |> Enum.map(fn {debt_id, i} ->
            %{
              label: debt_name(debts, debt_id),
              data: Enum.map(months, &dollars(line_value(&1, debt_id, :payment))),
              backgroundColor: color(i),
              borderColor: color(i),
              fill: true,
              tension: 0.15,
              pointRadius: 0,
              valueFormat: money_format(currency)
            }
          end)

        config = %{
          type: "line",
          data: %{labels: month_labels(months), datasets: datasets},
          options:
            base_options(%{
              interaction: %{mode: "index", intersect: false},
              scales: %{
                x: %{stacked: true},
                y: %{
                  stacked: true,
                  beginAtZero: true,
                  title: %{display: true, text: "Payment ($)"},
                  ticks: %{format: tick_money_format(currency)}
                }
              }
            })
        }

        {nil, config}

      message ->
        {message, nil}
    end
  end

  # --- freed cash flow: filled area chart --------------------------------------

  defp freed_cashflow_config(result, debts, currency) do
    case plan_message(result, "Add a debt to see cash flow freed over time.") do
      nil ->
        {:ok, %{months: months}} = result
        freed = Planning.freed_cashflow_from_months(debts, months)

        config = %{
          type: "line",
          data: %{
            labels: Enum.map(freed, &"Month #{&1.index}"),
            datasets: [
              %{
                label: "Monthly payment freed",
                data: Enum.map(freed, &dollars(&1.freed)),
                fill: true,
                backgroundColor: @freed_cashflow_fill,
                borderColor: color(0),
                tension: 0.15,
                pointRadius: 0,
                valueFormat: money_format(currency)
              }
            ]
          },
          options:
            base_options(%{
              scales: %{
                y: %{
                  beginAtZero: true,
                  title: %{display: true, text: "Freed per month ($)"},
                  ticks: %{format: tick_money_format(currency)}
                }
              }
            })
        }

        {nil, config}

      message ->
        {message, nil}
    end
  end

  # --- interest vs. principal: doughnut -----------------------------------------

  defp interest_breakdown_config(payments, currency) do
    payments = payments || []
    principal = Enum.reduce(payments, 0, &((Map.get(&1, :principal_portion) || 0) + &2))
    interest = Calculations.lifetime_interest_paid(payments)

    if principal + interest == 0 do
      {"Log a payment to start tracking this.", nil}
    else
      config = %{
        type: "doughnut",
        data: %{
          labels: ["Principal", "Interest"],
          datasets: [
            %{
              data: [dollars(principal), dollars(interest)],
              backgroundColor: [color(0), color(1)],
              valueFormat: money_format(currency)
            }
          ]
        },
        options: base_options(%{plugins: %{legend: %{position: "bottom"}}})
      }

      {nil, config}
    end
  end

  # --- retirement roadmap: baseline + one line per strategy -------------------

  defp retirement_roadmap([], _debts, _budget, _currency),
    do: {@no_retirement_profile_message, nil}

  defp retirement_roadmap(nil, _debts, _budget, _currency),
    do: {@no_retirement_profile_message, nil}

  defp retirement_roadmap(profiles, debts, budget, currency),
    do:
      {nil, retirement_roadmap_config(retirement_projections(profiles, debts, budget), currency)}

  @doc """
  Runs `Engine.Retirement` for the roadmap: the household horizon, the
  baseline series and each strategy's `{:ok, series} | {:error, reason}`, in
  the shape `retirement_roadmap_config/2` takes. `profiles` are the
  snapshot's `retirement_profiles`, `debts` engine debt maps.
  """
  def retirement_projections(profiles, debts, budget) do
    %{
      months: Retirement.combined_months_to_retirement(profiles),
      baseline: %{
        balances: Retirement.baseline_projection(profiles),
        contributions: Retirement.baseline_contributions(profiles)
      },
      strategies:
        Map.new(
          @strategies,
          &{&1, Retirement.strategy_projection_with_contributions(debts, profiles, budget, &1)}
        )
    }
  end

  @doc """
  The retirement roadmap chart from projections (`retirement_projections/3`,
  integer cents), ported from `DebtReliefTrackerWeb.Charts.retirement_roadmap_chart/3`:

      %{
        months: household_months_to_retirement,
        baseline: %{balances: [cents, ...], contributions: [cents, ...]},
        strategies: %{cash_flow: {:ok, %{balances: [...], contributions: [...]}}
                                 | {:error, reason}, ...}
      }

  `balances` has `months + 1` entries (the starting balance first) and
  `contributions` one per month, as `Engine.Retirement` returns them.
  Errored strategies are left out; the baseline always stays.
  """
  def retirement_roadmap_config(projections, currency \\ "USD") do
    years = div(projections.months, 12)
    labels = for y <- 0..years, do: "Year #{y}"

    baseline_dataset = %{
      label: "Baseline (no debt strategy)",
      data: yearly_samples(projections.baseline.balances),
      afterLabels: contribution_lines(projections.baseline.contributions, currency),
      borderColor: @total_line_color,
      backgroundColor: @total_line_color,
      borderDash: [6, 4],
      fill: false,
      tension: 0.2,
      pointRadius: 0,
      valueFormat: money_format(currency)
    }

    strategy_datasets =
      @strategies
      |> Enum.with_index()
      |> Enum.flat_map(fn {strategy, i} ->
        case Map.get(projections.strategies, strategy) do
          {:ok, %{balances: balances, contributions: contributions}} ->
            [
              %{
                label: strategy_label(strategy),
                data: yearly_samples(balances),
                afterLabels: contribution_lines(contributions, currency),
                borderColor: color(i),
                backgroundColor: color(i),
                fill: false,
                tension: 0.2,
                pointRadius: 0,
                valueFormat: money_format(currency)
              }
            ]

          _error_or_missing ->
            []
        end
      end)

    %{
      type: "line",
      data: %{labels: labels, datasets: [baseline_dataset | strategy_datasets]},
      options:
        base_options(%{
          interaction: %{mode: "index", intersect: false},
          scales: %{
            x: %{title: %{display: true, text: "Years from now"}},
            y: %{
              beginAtZero: true,
              title: %{display: true, text: "Projected retirement savings ($)"},
              ticks: %{format: tick_money_format(currency)}
            }
          }
        })
    }
  end

  defp yearly_samples(monthly_balances),
    do: monthly_balances |> Enum.take_every(12) |> Enum.map(&dollars/1)

  # One contribution figure per label: the rate in effect at the start of
  # each year (year 0 = month 1's), clamped to the last month for the final
  # label -- matching `yearly_samples/1`'s sampling of the one-longer balance
  # series. Pre-rendered as the tooltip's extra line.
  defp contribution_lines(contributions, currency) do
    count = length(contributions)

    if count == 0 do
      []
    else
      Enum.map(0..div(count, 12), fn year ->
        cents = Enum.at(contributions, min(year * 12, count - 1))
        "Contributing #{money_text(cents, currency)}/mo"
      end)
    end
  end

  # --- theming ----------------------------------------------------------------

  @doc """
  `%{light: config, dark: config}`: the dark variant swaps every dataset
  color that is one of this module's light literals for its dark
  counterpart (by value, so it doesn't matter which dataset got which
  color). The facade picks the variant for the page's current theme.
  """
  def theme_variants(config), do: %{light: config, dark: themed(config, :dark)}

  def themed(config, :light), do: config

  def themed(%{data: %{datasets: datasets} = data} = config, :dark) do
    datasets =
      Enum.map(datasets, fn dataset ->
        dataset
        |> swap_key(:backgroundColor)
        |> swap_key(:borderColor)
      end)

    %{config | data: %{data | datasets: datasets}}
  end

  defp swap_key(dataset, key) do
    case Map.fetch(dataset, key) do
      {:ok, value} -> Map.put(dataset, key, dark_color(value))
      :error -> dataset
    end
  end

  defp dark_color(colors) when is_list(colors), do: Enum.map(colors, &dark_color/1)
  defp dark_color(@total_line_color), do: @dark_total_line_color
  defp dark_color(@freed_cashflow_fill), do: @dark_freed_cashflow_fill

  defp dark_color(color) do
    case Enum.find_index(@palette, &(&1 == color)) do
      nil -> color
      i -> Enum.at(@dark_palette, i)
    end
  end

  # --- helpers ----------------------------------------------------------------

  @doc """
  Integer cents -> a plain dollar string with exactly two decimals
  (`123456` -> `"1234.56"`, `-5` -> `"-0.05"`), the unit Chart.js plots.
  """
  def dollars(cents) when is_integer(cents) do
    sign = if cents < 0, do: "-", else: ""
    abs_cents = abs(cents)
    "#{sign}#{div(abs_cents, 100)}.#{pad2(rem(abs_cents, 100))}"
  end

  defp pad2(n) when n < 10, do: "0#{n}"
  defp pad2(n), do: Integer.to_string(n)

  # "$1,234.56"-style text for pre-rendered tooltip lines. Kept local (rather
  # than calling the web layer's Holo.Format) so the engine has no web deps;
  # the same symbols and grouping.
  defp money_text(cents, currency) do
    [whole, frac] = cents |> abs() |> dollars() |> String.split(".")
    sign = if cents < 0, do: "-", else: ""
    "#{sign}#{currency_symbol(currency)}#{group_thousands(whole)}.#{frac}"
  end

  defp currency_symbol("EUR"), do: "€"
  defp currency_symbol("GBP"), do: "£"
  defp currency_symbol("JPY"), do: "¥"
  defp currency_symbol(_usd_cad_aud_or_unknown), do: "$"

  defp group_thousands(digits) do
    len = String.length(digits)

    if len <= 3 do
      digits
    else
      group_thousands(String.slice(digits, 0, len - 3)) <> "," <> String.slice(digits, len - 3, 3)
    end
  end

  defp debt_ids([first | _]), do: Enum.map(first.lines, & &1.debt_id)

  defp line_value(month, debt_id, key) do
    month.lines |> Enum.find(&(&1.debt_id == debt_id)) |> Map.fetch!(key)
  end

  defp month_labels(months), do: Enum.map(months, &"Month #{&1.index}")

  defp base_options(extra) do
    Map.merge(%{responsive: true, maintainAspectRatio: false, locale: "en-US"}, extra)
  end

  # Intl.NumberFormat options (see the moduledoc): exact cents in tooltips,
  # whole units on axis ticks, pluralized months for the comparison chart.
  defp money_format(currency), do: %{style: "currency", currency: currency}

  defp tick_money_format(currency),
    do: %{
      style: "currency",
      currency: currency,
      minimumFractionDigits: 0,
      maximumFractionDigits: 0
    }

  defp months_format, do: %{style: "unit", unit: "month", unitDisplay: "long"}

  defp color(i), do: Enum.at(@palette, rem(i, length(@palette)))
end
