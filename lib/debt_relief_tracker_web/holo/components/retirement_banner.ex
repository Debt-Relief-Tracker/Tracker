defmodule DebtReliefTrackerWeb.Holo.Components.RetirementBanner do
  @moduledoc """
  The "set up your retirement plan" prompt shown at the top of the dashboard's
  main panel until someone has a retirement profile or the prompt is
  dismissed (`DashboardLive`'s `#retirement-onboarding-banner`).

  Mount as the first child of `<main>`:

      <RetirementBanner cid="retirement_banner" snapshot={@snapshot} />

  It renders nothing once a profile exists or the prompt was dismissed.
  "Set up" opens the roster modal (`RetirementModal`) through the page.
  """

  use Hologram.Component

  alias DebtReliefTrackerWeb.Holo.Context
  alias DebtReliefTrackerWeb.Holo.DataPath

  middleware DebtReliefTrackerWeb.Holo.Auth

  prop :snapshot, :map
  prop :e2ee, :boolean, from_context: :e2ee

  @doc "True when the banner should show: no profiles yet and not dismissed."
  def show?(snapshot) do
    snapshot.retirement_profiles == [] and not snapshot.settings.retirement_onboarding_dismissed
  end

  def template do
    ~HOLO"""
    {%if show?(@snapshot)}
      <div
        id="retirement-onboarding-banner"
        class="alert alert-info flex items-center justify-between flex-wrap gap-2"
      >
        <span>See how paying off debt sooner could grow your retirement savings.</span>
        <div class="flex items-center gap-2">
          <button
            type="button"
            id="open-retirement-onboarding"
            class="btn btn-primary btn-sm min-h-9 sm:min-h-0"
            $click={action: :open_modal, target: "page", params: %{modal: %{type: :retirement_onboarding}}}
          >
            Set up retirement plan
          </button>
          <button
            type="button"
            id="dismiss-retirement-banner"
            class="btn btn-ghost btn-xs"
            aria-label="Dismiss"
            $click="dismiss"
          >
            &times;
          </button>
        </div>
      </div>
    {/if}
    """
  end

  def action(:dismiss, _params, component) do
    DataPath.save(component, :dismiss, %{},
      changes: [{:update_settings, %{retirement_onboarding_dismissed: true}}],
      ok: DataPath.ok(:snapshot_updated, "page"),
      error: DataPath.error(:change_failed, "page")
    )
  end

  def command(:dismiss, _params, server) do
    case Context.apply_change(
           server,
           {:update_settings, %{retirement_onboarding_dismissed: true}}
         ) do
      {:ok, snapshot} ->
        put_action(server, name: :snapshot_updated, target: "page", params: %{snapshot: snapshot})

      {:error, error} ->
        put_action(server, name: :change_failed, target: "page", params: %{error: error})
    end
  end
end
