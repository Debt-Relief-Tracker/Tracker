defmodule DebtReliefTrackerWeb.Holo.Components.PlanPanel do
  @moduledoc """
  Main panel: this-month card, strategy + budget controls, chart type picker
  and charts.

  STUB (only the this-month card works) -- owned by one feature agent; see
  docs/holo-ui-conventions.md.
  """

  use Hologram.Component

  alias DebtReliefTrackerWeb.Holo.Format
  alias DebtReliefTrackerWeb.Holo.Summary

  prop :snapshot, :map
  prop :account, :map
  prop :strategy, :atom

  def template do
    ~HOLO"""
    <section id="this-month-card" class="card bg-base-200 p-4">
      <h2 class="font-medium">This month</h2>
      {%for {:ok, month} <- [Summary.this_month(@snapshot, @strategy)]}
        <p>
          Put
          <strong>{Format.money(month.payment, @snapshot.settings.currency)}</strong>
          toward <strong>{month.target_name}</strong>
        </p>
      {/for}
      {%for {:error, reason} <- [Summary.this_month(@snapshot, @strategy)]}
        <p class="opacity-70">No plan yet ({reason})</p>
      {/for}
    </section>
    """
  end
end
