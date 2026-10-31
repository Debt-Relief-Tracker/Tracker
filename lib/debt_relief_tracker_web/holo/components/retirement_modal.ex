defmodule DebtReliefTrackerWeb.Holo.Components.RetirementModal do
  @moduledoc """
  Retirement onboarding + profile list/form modals (modal types :retirement_onboarding, :retirement_profile_form).

  STUB -- owned by one feature agent; see docs/holo-ui-conventions.md.
  """

  use Hologram.Component

  prop :snapshot, :map
  prop :account, :map
  prop :modal, :map, default: nil

  def template do
    ~HOLO"""
    <div id="retirement-modal-stub"></div>
    """
  end
end
