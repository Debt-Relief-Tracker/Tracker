defmodule DebtReliefTrackerWeb.Holo.Components.DebtSidebar do
  @moduledoc """
  Left rail: add-debt/log-all/activity buttons, debt list with per-debt actions, due-payment prompts.

  STUB -- owned by one feature agent; see docs/holo-ui-conventions.md.
  """

  use Hologram.Component

  prop :snapshot, :map
  prop :account, :map

  def template do
    ~HOLO"""
    <div id="debt-sidebar-stub"></div>
    """
  end
end
