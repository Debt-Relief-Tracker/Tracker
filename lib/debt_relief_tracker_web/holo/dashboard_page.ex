defmodule DebtReliefTrackerWeb.Holo.DashboardPage do
  @moduledoc """
  The Hologram dashboard (docs/architecture/0007-e2ee.md, roadmap Phase 10).
  Served at `/app` alongside the LiveView at `/` until it reaches parity.

  This page only owns shared state and layout; every feature lives in a
  component under `Holo.Components.*` (see docs/holo-ui-conventions.md):

    * `:snapshot` -- a `Storage` snapshot, the single source of truth for all
      financial data. Everything displayed is derived from it by the shared
      integer engine.
    * `:account` -- plain account/session data (user, workspace, OIDC flag).
    * `:modal` -- `nil` or `%{type: atom, ...}`; at most one modal is open.
    * `:strategy` -- the selected payoff strategy.
  """

  use Hologram.Page

  alias DebtReliefTrackerWeb.Holo.Components.ActivityLogModal
  alias DebtReliefTrackerWeb.Holo.Components.DebtFormModal
  alias DebtReliefTrackerWeb.Holo.Components.DebtSidebar
  alias DebtReliefTrackerWeb.Holo.Components.Footer
  alias DebtReliefTrackerWeb.Holo.Components.HeaderBar
  alias DebtReliefTrackerWeb.Holo.Components.LogAllBalancesModal
  alias DebtReliefTrackerWeb.Holo.Components.PaymentModal
  alias DebtReliefTrackerWeb.Holo.Components.PlanPanel
  alias DebtReliefTrackerWeb.Holo.Components.RetirementBanner
  alias DebtReliefTrackerWeb.Holo.Components.RetirementModal
  alias DebtReliefTrackerWeb.Holo.Components.SettingsModal
  alias DebtReliefTrackerWeb.Holo.Components.TutorialOverlay
  alias DebtReliefTrackerWeb.Holo.Context

  route "/app"
  layout DebtReliefTrackerWeb.Holo.Layout

  middleware DebtReliefTrackerWeb.Holo.Auth

  # Server, first render. In E2EE mode this will render a locked shell
  # instead and never touch plaintext.
  def init(_params, component, server) do
    {:ok, snapshot} = Context.load(server)

    component
    |> put_state(:snapshot, snapshot)
    |> put_state(:account, Context.account(server))
    |> put_state(:strategy, :cash_flow)
    |> put_state(:modal, nil)
    |> put_state(:error, nil)
  end

  def template do
    ~HOLO"""
    <div id="holo-dashboard" class="flex flex-col min-h-screen">
      <HeaderBar cid="header_bar" snapshot={@snapshot} account={@account} />

      <div class="flex flex-col sm:flex-row flex-1 min-h-0">
        <aside class="w-full sm:w-1/5 sm:min-w-[220px] border-b sm:border-b-0 sm:border-r border-base-300 p-3 flex flex-col gap-3 min-h-0">
          <DebtSidebar cid="debt_sidebar" snapshot={@snapshot} account={@account} />
        </aside>

        <main class="flex-1 p-4 min-w-0 flex flex-col gap-4">
          <RetirementBanner cid="retirement_banner" snapshot={@snapshot} />
          <PlanPanel cid="plan_panel" snapshot={@snapshot} account={@account} strategy={@strategy} />
        </main>
      </div>

      <Footer cid="footer" account={@account} />
      <TutorialOverlay cid="tutorial_overlay" snapshot={@snapshot} account={@account} />

      {%if @modal}
        {%if @modal.type == :add_debt || @modal.type == :edit_debt}
          <DebtFormModal cid="debt_form_modal" snapshot={@snapshot} account={@account} modal={@modal} />
        {/if}
        {%if @modal.type == :log_payment}
          <PaymentModal cid="payment_modal" snapshot={@snapshot} account={@account} modal={@modal} />
        {/if}
        {%if @modal.type == :log_all_balances}
          <LogAllBalancesModal cid="log_all_balances_modal" snapshot={@snapshot} account={@account} modal={@modal} />
        {/if}
        {%if @modal.type == :activity_log}
          <ActivityLogModal cid="activity_log_modal" snapshot={@snapshot} account={@account} modal={@modal} />
        {/if}
        {%if @modal.type == :settings}
          <SettingsModal cid="settings_modal" snapshot={@snapshot} account={@account} modal={@modal} />
        {/if}
        {%if @modal.type == :retirement_onboarding || @modal.type == :retirement_profile_form}
          <RetirementModal cid="retirement_modal" snapshot={@snapshot} account={@account} modal={@modal} />
        {/if}
      {/if}
    </div>
    """
  end

  # --- shared actions (children target these with `target: "page"`) -------

  # A child (or a command's reply) delivers a fresh snapshot.
  # Pass `close_modal: true` to also close the open modal -- a handler can
  # queue only ONE follow-up action (a second `put_action` overwrites the
  # first), so "update the snapshot and close" has to be a single action.
  def action(:snapshot_updated, %{snapshot: snapshot} = params, component) do
    component
    |> put_state(:snapshot, snapshot)
    |> put_state(:error, nil)
    |> put_state(:modal, if(Map.get(params, :close_modal), do: nil, else: component.state.modal))
  end

  def action(:change_failed, %{error: error}, component), do: put_state(component, :error, error)

  def action(:account_updated, %{account: account}, component),
    do: put_state(component, :account, account)

  def action(:open_modal, %{modal: modal}, component), do: put_state(component, :modal, modal)
  def action(:close_modal, _params, component), do: put_state(component, :modal, nil)

  def action(:select_strategy, %{strategy: strategy}, component),
    do: put_state(component, :strategy, strategy)
end
