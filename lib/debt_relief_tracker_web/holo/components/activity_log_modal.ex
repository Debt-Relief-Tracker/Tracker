defmodule DebtReliefTrackerWeb.Holo.Components.ActivityLogModal do
  @moduledoc """
  Activity log modal (modal type `:activity_log`). Rendered entirely from
  `snapshot.activity` via the client-safe `Holo.Activity` helpers. The one
  thing the snapshot lacks is who did it (entries carry only a `user_id`),
  so on open a `load_actors` command fetches the display names of the
  workspace's members -- account data, not part of the snapshot.
  """

  use Hologram.Component

  alias DebtReliefTrackerWeb.Holo.AccountOps
  alias DebtReliefTrackerWeb.Holo.Activity
  alias DebtReliefTrackerWeb.Holo.Context

  middleware DebtReliefTrackerWeb.Holo.Auth

  prop :snapshot, :map
  prop :account, :map
  prop :modal, :map, default: nil

  def init(_props, component) do
    component
    |> put_state(:actors, %{})
    |> put_command(:load_actors)
  end

  def init(props, component, server), do: {init(props, component), server}

  def template do
    ~HOLO"""
    <div id="activity-log-modal" class="fixed inset-0 bg-black/50 flex items-center justify-center p-4 sm:p-0 z-50">
      <window $key_down.escape={action: :close_modal, target: "page"} />
      <div
        class="bg-base-100 rounded-lg p-4 sm:p-6 w-full max-w-2xl max-h-[90vh] overflow-y-auto"
        $click_outside={action: :close_modal, target: "page"}
      >
        <h2 class="font-semibold text-lg mb-4">Activity log</h2>

        <div class="overflow-x-auto">
          <table id="activity-log-entries" class="table">
            <thead>
              <tr>
                <th>When</th>
                <th>Activity</th>
              </tr>
            </thead>
            <tbody>
              {%for entry <- Enum.take(@snapshot.activity, 50)}
                <tr id={"activity-#{entry.id}"}>
                  <td class="whitespace-nowrap">{Activity.format_when(entry.inserted_at)}</td>
                  <td>{Activity.description(entry, @snapshot.debts, @actors, @snapshot.settings.currency)}</td>
                </tr>
              {/for}
            </tbody>
          </table>
        </div>

        <div class="flex justify-end mt-4">
          <button
            id="activity-log-close"
            type="button"
            class="btn"
            $click={action: :close_modal, target: "page"}
          >
            Close
          </button>
        </div>
      </div>
    </div>
    """
  end

  def action(:actors_loaded, %{actors: actors}, component),
    do: put_state(component, :actors, actors)

  def command(:load_actors, _params, server) do
    actors = AccountOps.actor_names(Context.workspace(server))
    put_action(server, :actors_loaded, actors: actors)
  end
end
