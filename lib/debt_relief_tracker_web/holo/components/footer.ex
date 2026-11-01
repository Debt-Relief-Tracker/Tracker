defmodule DebtReliefTrackerWeb.Holo.Components.Footer do
  @moduledoc """
  App footer plus the donate modal (ported from `Layouts.app_footer`).
  The modal's open/closed flag is local component state; no page modal.
  Mobile: the footer wraps onto two lines with edge padding.
  """

  use Hologram.Component

  prop :account, :map

  def init(_props, component, _server), do: put_state(component, :donate_open, false)

  def template do
    ~HOLO"""
    <footer
      id="app-footer"
      class="shrink-0 min-h-10 py-2 flex flex-wrap items-center justify-center gap-x-2 gap-y-1 border-t border-base-300 text-sm text-base-content/70 px-4 sm:h-10 sm:py-0 sm:px-0 sm:gap-2"
    >
      <span class="basis-full text-center sm:basis-auto">Debt Relief Tracker</span>
      <span aria-hidden="true" class="hidden sm:inline">·</span>
      <a
        href="https://github.com/Debt-Relief-Tracker/Tracker"
        target="_blank"
        rel="noopener noreferrer"
        class="link link-hover"
      >GitHub</a>
      <span aria-hidden="true">·</span>
      <a
        href="https://github.com/Debt-Relief-Tracker/Tracker/blob/main/LICENSE"
        target="_blank"
        rel="noopener noreferrer"
        class="link link-hover"
      >MIT License</a>
      <span aria-hidden="true">·</span>
      <button type="button" id="donate-link" class="link link-hover" $click={:open_donate}>Donate</button>
      {%if @account.oidc_enabled == false || @account.user.is_admin}
        <span aria-hidden="true">·</span>
        <a id="admin-link" href="/admin" class="link link-hover">Admin</a>
      {/if}

      <div
        id="donate-modal"
        class={donate_modal_class(@donate_open)}
      >
        <div class="absolute inset-0" $click={:close_donate}></div>
        <div class="relative bg-base-100 rounded-lg p-4 sm:p-6 w-full max-w-2xl max-h-[90vh] overflow-y-auto">
          <div class="space-y-4 text-base-content">
            <div class="flex items-center justify-between gap-2">
              <h2 class="text-lg font-semibold">Ways to donate</h2>
              <button
                type="button"
                id="donate-modal-close"
                class="btn btn-ghost btn-sm btn-square"
                aria-label="Close"
                $click={:close_donate}
              >✕</button>
            </div>
            <p class="text-base-content/70">
              GitHub Sponsors is pending approval. In the meantime, you can donate via Liberapay or Ko-fi.
            </p>
            <div class="grid grid-cols-1 gap-3 sm:grid-cols-3">
              <div
                id="donate-github-sponsors"
                aria-disabled="true"
                class="rounded-lg border border-dashed border-base-300 p-4 flex items-center justify-center text-center text-sm text-base-content/40"
              >GitHub Sponsors — coming soon</div>
              <a
                id="donate-liberapay"
                href="https://liberapay.com/DebtReliefTracker/"
                target="_blank"
                rel="noopener noreferrer"
                class="rounded-lg border border-primary/30 p-4 flex items-center justify-center text-center font-semibold text-primary hover:bg-primary/5 transition-colors"
              >Liberapay</a>
              <a
                id="donate-ko-fi"
                href="https://ko-fi.com/calonmerc"
                target="_blank"
                rel="noopener noreferrer"
                class="rounded-lg border border-primary/30 p-4 flex items-center justify-center text-center font-semibold text-primary hover:bg-primary/5 transition-colors"
              >Ko-fi</a>
            </div>
          </div>
        </div>
      </div>
    </footer>
    """
  end

  @doc "Class for the donate modal backdrop; `hidden` while closed."
  def donate_modal_class(open?) do
    base = "fixed inset-0 bg-black/50 flex items-center justify-center p-4 sm:p-0 z-50"
    if open?, do: base, else: base <> " hidden"
  end

  def action(:open_donate, _params, component), do: put_state(component, :donate_open, true)
  def action(:close_donate, _params, component), do: put_state(component, :donate_open, false)
end
