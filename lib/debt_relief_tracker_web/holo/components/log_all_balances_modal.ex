defmodule DebtReliefTrackerWeb.Holo.Components.LogAllBalancesModal do
  @moduledoc """
  Log-all-balances modal (modal type :log_all_balances).

  STUB -- owned by one feature agent; see docs/holo-ui-conventions.md.
  """

  use Hologram.Component

  prop :snapshot, :map
  prop :account, :map
  prop :modal, :map, default: nil

  def template do
    ~HOLO"""
    <div id="log-all-balances-modal-stub"></div>
    """
  end
end
