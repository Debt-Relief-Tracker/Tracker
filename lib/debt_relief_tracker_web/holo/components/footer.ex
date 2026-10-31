defmodule DebtReliefTrackerWeb.Holo.Components.Footer do
  @moduledoc """
  App footer incl. donate modal trigger.

  STUB -- owned by one feature agent; see docs/holo-ui-conventions.md.
  """

  use Hologram.Component

  prop :account, :map

  def template do
    ~HOLO"""
    <div id="footer-stub"></div>
    """
  end
end
