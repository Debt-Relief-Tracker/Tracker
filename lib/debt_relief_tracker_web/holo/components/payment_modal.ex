defmodule DebtReliefTrackerWeb.Holo.Components.PaymentModal do
  @moduledoc """
  Log-payment modal (modal type :log_payment).

  STUB -- owned by one feature agent; see docs/holo-ui-conventions.md.
  """

  use Hologram.Component

  prop :snapshot, :map
  prop :account, :map
  prop :modal, :map, default: nil

  def template do
    ~HOLO"""
    <div id="payment-modal-stub"></div>
    """
  end
end
