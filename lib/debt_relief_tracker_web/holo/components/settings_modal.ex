defmodule DebtReliefTrackerWeb.Holo.Components.SettingsModal do
  @moduledoc """
  Settings modal: name, currency, theme, export, workspace sharing (modal type :settings).

  STUB -- owned by one feature agent; see docs/holo-ui-conventions.md.
  """

  use Hologram.Component

  prop :snapshot, :map
  prop :account, :map
  prop :modal, :map, default: nil

  def template do
    ~HOLO"""
    <div id="settings-modal-stub"></div>
    """
  end
end
