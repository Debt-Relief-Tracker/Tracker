defmodule DebtReliefTrackerWeb.Holo.Components.DebtFormModal do
  @moduledoc """
  Add / edit debt modal (modal types :add_debt, :edit_debt).

  STUB -- owned by one feature agent; see docs/holo-ui-conventions.md.
  """

  use Hologram.Component

  prop :snapshot, :map
  prop :account, :map
  prop :modal, :map, default: nil

  def template do
    ~HOLO"""
    <div id="debt-form-modal-stub"></div>
    """
  end
end
