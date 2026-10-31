defmodule DebtReliefTrackerWeb.Holo.Components.TutorialOverlay do
  @moduledoc """
  First-run tutorial overlay.

  STUB -- owned by one feature agent; see docs/holo-ui-conventions.md.
  """

  use Hologram.Component

  prop :snapshot, :map
  prop :account, :map

  def template do
    ~HOLO"""
    <div id="tutorial-overlay-stub"></div>
    """
  end
end
