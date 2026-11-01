defmodule DebtReliefTrackerWeb.Holo.Components.DebtModalFrame do
  @moduledoc """
  Stateless overlay + dialog box shared by the debt modals (the Hologram
  counterpart of `DashboardLive`'s private `modal/1`). Escape or a click
  outside closes the page's modal.
  """

  use Hologram.Component

  prop :id, :string, required: true

  def template do
    ~HOLO"""
    <div id={@id} class="fixed inset-0 bg-black/50 flex items-center justify-center p-4 sm:p-0 z-50">
      <window $key_down.escape={action: :close_modal, target: "page"} />
      <div
        class="bg-base-100 rounded-lg p-4 sm:p-6 w-full max-w-2xl max-h-[90vh] overflow-y-auto"
        $click_outside={action: :close_modal, target: "page"}
      >
        <slot />
      </div>
    </div>
    """
  end
end
