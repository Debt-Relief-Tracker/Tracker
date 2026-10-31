defmodule DebtReliefTrackerWeb.Holo.Components.HeaderBar do
  @moduledoc """
  Top bar: workspace name/switcher, settings button, user + logout, theme toggle.

  STUB -- owned by one feature agent; see docs/holo-ui-conventions.md.
  """

  use Hologram.Component

  prop :snapshot, :map
  prop :account, :map

  def template do
    ~HOLO"""
    <div id="header-bar-stub"></div>
    """
  end
end
