defmodule DebtReliefTrackerWeb.Holo.Components.ActivityLogModal do
  @moduledoc """
  Activity log modal (modal type :activity_log).

  STUB -- owned by one feature agent; see docs/holo-ui-conventions.md.
  """

  use Hologram.Component

  prop :snapshot, :map
  prop :account, :map
  prop :modal, :map, default: nil

  def template do
    ~HOLO"""
    <div id="activity-log-modal-stub"></div>
    """
  end
end
