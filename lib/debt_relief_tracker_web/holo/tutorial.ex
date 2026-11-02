defmodule DebtReliefTrackerWeb.Holo.Tutorial do
  @moduledoc """
  Client-safe data and pure step arithmetic for the onboarding tutorial
  (ported from `@tutorial_steps` in `DashboardLive`).

  A step with no `:target` is a centered welcome card (no spotlight). Targets
  are DOM ids that other components render:

    * `#add-debt-button` (DebtSidebar)
    * `#debt-list` (DebtSidebar)
    * `#budget-input` (PlanPanel)
    * `#chart-type-switcher` (PlanPanel)
    * `#strategy-switcher` (PlanPanel; only rendered for some chart types,
      hence `:chart_type` on steps 5-6)
    * `#settings-button` (HeaderBar)
  """

  @steps [
    %{
      target: nil,
      title: "Welcome to your debt tracker",
      body: "A quick tour of the essentials -- feel free to skip anytime.",
      chart_type: nil
    },
    %{
      target: "#add-debt-button",
      title: "Add a debt",
      body: "Start here to add each loan, credit card, or line of credit you're tracking.",
      chart_type: nil
    },
    %{
      target: "#debt-list",
      title: "Your debts",
      body:
        "Every debt you add shows up here, with quick actions to log a payment, edit, or mark it paid off.",
      chart_type: nil
    },
    %{
      target: "#budget-input",
      title: "Set your budget",
      body:
        "Tell us how much you can put toward debt each month -- this drives every payoff projection.",
      chart_type: nil
    },
    %{
      target: "#chart-type-switcher",
      title: "Chart views",
      body:
        "Switch between comparing strategies, simulating a payoff plan, and other views of your progress.",
      chart_type: :comparison
    },
    %{
      target: "#strategy-switcher",
      title: "Payoff strategies",
      body:
        "Compare snowball, avalanche, and cash-flow strategies to see which pays off your debt fastest.",
      chart_type: :simulation
    },
    %{
      target: "#settings-button",
      title: "Settings",
      body:
        "Set your currency, export your data, and come back here anytime to view this tutorial again.",
      chart_type: nil
    }
  ]

  # Plain dim backdrop + centered card, for steps with no target (must match
  # the no-target fallback in assets/js/tutorial_overlay.mjs).
  @backdrop_style "position:fixed;inset:0;z-index:9998;background:rgba(0,0,0,0.6);transition:clip-path 0.2s ease;"
  @centered_card_style "position:fixed;z-index:9999;top:50%;left:50%;transform:translate(-50%,-50%);"

  def backdrop_style, do: @backdrop_style
  def centered_card_style, do: @centered_card_style

  def steps, do: @steps

  def count, do: length(@steps)

  @doc "The step at zero-based `index` (clamped into range)."
  def step(index) do
    Enum.at(@steps, max(min(index, count() - 1), 0))
  end

  @doc "`{:step, n}` for the step after `index`, or `:finish` past the last."
  def next(index) do
    if index + 1 < count(), do: {:step, index + 1}, else: :finish
  end

  @doc "The step before `index` (never below the first)."
  def prev(index), do: {:step, max(index - 1, 0)}

  @doc "What the overlay card renders for the step at `index`."
  def view(index) do
    step = step(index)

    %{
      target: step.target,
      title: step.title,
      body: step.body,
      progress: "Step " <> Integer.to_string(index + 1) <> " of " <> Integer.to_string(count()),
      first?: index == 0,
      next_label: if(index == count() - 1, do: "Finish", else: "Next")
    }
  end
end
