defmodule DebtReliefTrackerWeb.Holo.Components.SettingsModal do
  @moduledoc """
  Settings modal (modal type `:settings`): editable display name, tracker
  name, currency (one Save for all three), CSV export links, restart
  tutorial, retirement entry point, and workspace sharing (OIDC owners).

  Port of `DashboardLive`'s `settings_modal/1` and the `open_settings`,
  `validate_settings`, `save_settings`, `share_workspace`,
  `cancel_invitation`, `remove_member` handlers.

  The `modal` prop (opened by `HeaderBar`'s `open_settings` command) carries
  the server-only facts: `is_owner`, `display_name_editability`,
  `accepted_members`, `pending_invitations`, plus `notice` / `error` from the
  last sharing operation. Form fields are component state (`*_input`);
  `validate_settings` is just those keystroke actions. Every command
  re-derives user and workspace from `Holo.Context` and re-checks
  authorization in `Holo.AccountOps`, so a crafted command can't reach a
  section the UI hides.
  """

  use Hologram.Component

  alias DebtReliefTrackerWeb.Holo.AccountOps
  alias DebtReliefTrackerWeb.Holo.Context
  alias DebtReliefTrackerWeb.Holo.CsvDownload
  alias DebtReliefTrackerWeb.Holo.CsvExport
  alias DebtReliefTrackerWeb.Holo.DataPath
  alias DebtReliefTrackerWeb.Holo.Format

  middleware DebtReliefTrackerWeb.Holo.Auth

  prop :snapshot, :map
  prop :account, :map
  prop :modal, :map, default: nil
  prop :e2ee, :boolean, from_context: :e2ee

  def init(props, component) do
    put_state(component,
      name_input: props.account.user.display_name,
      ws_name_input: props.account.workspace.name,
      currency_input: props.snapshot.settings.currency,
      share_email: "",
      display_name_error: nil,
      ws_name_error: nil,
      general_error: nil
    )
  end

  def init(props, component, server), do: {init(props, component), server}

  def template do
    ~HOLO"""
    <div id="settings-modal" class="fixed inset-0 bg-black/50 flex items-center justify-center p-4 sm:p-0 z-50">
      <window $key_down.escape={action: :close_modal, target: "page"} />
      <div
        id="settings-dialog"
        class="bg-base-100 rounded-lg p-4 sm:p-6 w-full max-w-2xl max-h-[90vh] overflow-y-auto"
        $click_outside={action: :close_modal, target: "page"}
      >
        <h2 class="font-semibold text-lg mb-4">Settings</h2>

        {%if @general_error}
          <p id="settings-error" class="text-sm text-error mb-4">{@general_error}</p>
        {/if}

        <form id="settings-form" $submit="save">
          <section class="mb-6">
            <h3 class="font-medium mb-2">Your name</h3>
            {%if @modal.display_name_editability == :read_only}
              <p id="display-name-read-only" class="text-sm">{@account.user.display_name}</p>
              <p class="text-xs opacity-70 mt-1">
                Managed by your sign-in provider (e.g. Google). Change it there.
              </p>
            {%else}
              <input
                id="settings-display-name"
                type="text"
                name="user[display_name]"
                class="input w-full"
                value={@name_input}
                $change="set_name"
              />
              {%if @display_name_error}
                <p id="display-name-error" class="text-sm text-error mt-1">{@display_name_error}</p>
              {/if}
              {%if @modal.display_name_editability == :idp}
                <p class="text-xs opacity-70">Also updates your sign-in profile.</p>
              {/if}
              {%if @modal.display_name_editability == :local_override}
                <p class="text-xs opacity-70">
                  Saved in this app only. Your sign-in provider's name won't replace it.
                </p>
              {/if}
            {/if}
          </section>

          <section class="mb-6">
            <h3 class="font-medium mb-2">Tracker name</h3>
            {%if @modal.is_owner}
              <input
                id="settings-workspace-name"
                type="text"
                name="workspace[name]"
                class="input w-full"
                value={@ws_name_input}
                $change="set_ws_name"
              />
              {%if @ws_name_error}
                <p id="workspace-name-error" class="text-sm text-error mt-1">{@ws_name_error}</p>
              {/if}
            {%else}
              <p class="text-sm opacity-70">{@account.workspace.name}</p>
            {/if}
          </section>

          <section class="mb-6">
            <h3 class="font-medium mb-2">Currency</h3>
            {%if @modal.is_owner}
              <select
                id="settings-currency"
                name="currency"
                class="select select-sm"
                value={@currency_input}
                $change="set_currency"
              >
                {%for code <- Format.currency_codes()}
                  <option value={code} selected={code == @currency_input}>{code}</option>
                {/for}
              </select>
            {%else}
              <p class="text-sm opacity-70">{@snapshot.settings.currency}</p>
            {/if}
          </section>
        </form>

        <section class="mb-6">
          <h3 class="font-medium mb-2">Export</h3>
          <div class="flex flex-col gap-2">
            {%if @e2ee}
              <button id="export-debts" type="button" class="btn btn-soft btn-sm w-full" $click="export_debts">
                Export debts (CSV)
              </button>
              <button id="export-payments" type="button" class="btn btn-soft btn-sm w-full" $click="export_payments">
                Export payments (CSV)
              </button>
            {%else}
              <a id="export-debts" href="/export/debts.csv" class="btn btn-soft btn-sm w-full">
                Export debts (CSV)
              </a>
              <a id="export-payments" href="/export/payments.csv" class="btn btn-soft btn-sm w-full">
                Export payments (CSV)
              </a>
            {/if}
          </div>
        </section>

        <section class="mb-6">
          <h3 class="font-medium mb-2">Tutorial</h3>
          <button
            id="restart-tutorial"
            type="button"
            class="btn btn-soft btn-sm"
            $click={action: :restart_tutorial, target: "page"}
          >
            View tutorial again
          </button>
        </section>

        <section class="mb-6">
          <h3 class="font-medium mb-2">Retirement planning</h3>
          <button
            id="open-retirement"
            type="button"
            class="btn btn-soft btn-sm"
            $click={action: :open_modal, target: "page", params: %{modal: %{type: :retirement_onboarding}}}
          >
            Retirement profiles
          </button>
        </section>

        {%if @e2ee}
          {%if @account.oidc_enabled}
            <section id="settings-people-e2ee">
              <h3 class="font-medium mb-2">People</h3>
              <p class="text-sm opacity-70">
                Sharing is not available with end-to-end encryption: only you can open this vault,
                because the key never leaves your browser.
              </p>
            </section>
          {/if}
        {%else}
        {%if @account.oidc_enabled}
          {%if @modal.is_owner}
            <section id="settings-people">
              <h3 class="font-medium mb-2">People</h3>
              <form id="settings-share-form" class="flex items-center gap-2 mb-3" $submit="share">
                <input
                  id="settings-share-email"
                  type="email"
                  name="share[email]"
                  placeholder="Invite by email…"
                  class="input input-sm flex-1"
                  value={@share_email}
                  $change="set_share_email"
                />
                <button id="settings-share-submit" type="submit" class="btn btn-sm min-h-9 sm:min-h-0">Invite</button>
              </form>

              {%if @modal.notice}
                <p id="settings-notice" class="text-sm text-success mb-2">{@modal.notice}</p>
              {/if}
              {%if @modal.error}
                <p id="settings-share-error" class="text-sm text-error mb-2">{@modal.error}</p>
              {/if}

              <ul id="settings-people-list" class="flex flex-col gap-1">
                {%for invitation <- @modal.pending_invitations}
                  <li id={"invitation-#{invitation.id}"} class="flex items-center justify-between text-sm">
                    <span>{invitation.email} <span class="badge badge-ghost badge-sm">pending</span></span>
                    <button
                      id={"cancel-invitation-#{invitation.id}"}
                      type="button"
                      $click={command: :cancel_invitation, params: %{id: invitation.id}}
                      aria-label={"Cancel invitation for #{invitation.email}"}
                    >
                      <span class="hero-x-mark w-3 h-3"></span>
                    </button>
                  </li>
                {/for}
                {%for member <- @modal.accepted_members}
                  <li id={"member-#{member.id}"} class="flex items-center justify-between text-sm">
                    <span>{member.name}</span>
                    <button
                      id={"remove-member-#{member.id}"}
                      type="button"
                      $click={command: :remove_member, params: %{id: member.id}}
                      aria-label={"Remove #{member.name}"}
                    >
                      <span class="hero-x-mark w-3 h-3"></span>
                    </button>
                  </li>
                {/for}
              </ul>
            </section>
          {/if}
        {/if}
        {/if}

        <div class="flex justify-end gap-2 mt-4">
          <button
            id="settings-cancel"
            type="button"
            class="btn"
            $click={action: :close_modal, target: "page"}
          >
            Cancel
          </button>
          {%if @modal.is_owner || @modal.display_name_editability != :read_only}
            <button id="settings-save" type="submit" form="settings-form" class="btn btn-primary">
              Save
            </button>
          {/if}
        </div>
      </div>
    </div>
    """
  end

  # --- actions (client) ----------------------------------------------------

  def action(:set_name, %{event: %{value: value}}, component),
    do: put_state(component, name_input: value, display_name_error: nil)

  def action(:set_ws_name, %{event: %{value: value}}, component),
    do: put_state(component, ws_name_input: value, ws_name_error: nil)

  def action(:set_currency, %{event: %{value: value}}, component),
    do: put_state(component, :currency_input, value)

  def action(:set_share_email, %{event: %{value: value}}, component),
    do: put_state(component, :share_email, value)

  # The single Save. The server decides which sections this user may write.
  # E2EE: the currency lives in the vault, so the server saves only the
  # account part (`:save_account`) and `:account_saved` applies the currency
  # through the ledger.
  def action(:save, _params, component) do
    state = component.state

    component =
      put_state(component, display_name_error: nil, ws_name_error: nil, general_error: nil)

    if DataPath.e2ee?(component) do
      put_command(component, :save_account,
        display_name: state.name_input,
        workspace_name: state.ws_name_input
      )
    else
      put_command(component, :save_settings,
        display_name: state.name_input,
        workspace_name: state.ws_name_input,
        currency: state.currency_input
      )
    end
  end

  def action(:account_saved, %{account: account}, component) do
    currency = component.state.currency_input

    if component.props.modal.is_owner and currency in Format.currency_codes() and
         currency != component.props.snapshot.settings.currency do
      DataPath.save(component, :unused, %{},
        changes: [{:update_settings, %{currency: currency}}],
        ok:
          DataPath.ok(:account_changed, "page", %{
            account: account,
            modal: nil,
            notice: "Settings saved."
          }),
        error: DataPath.error(:save_failed, "settings_modal")
      )
    else
      put_action(component,
        name: :account_changed,
        target: "page",
        params: %{
          account: account,
          snapshot: component.props.snapshot,
          modal: nil,
          notice: "Settings saved."
        }
      )
    end
  end

  def action(:export_debts, _params, component) do
    CsvDownload.download(
      "debts.csv",
      CsvExport.debts(component.props.snapshot),
      "#settings-dialog"
    )

    component
  end

  def action(:export_payments, _params, component) do
    CsvDownload.download(
      "payments.csv",
      CsvExport.payments(component.props.snapshot),
      "#settings-dialog"
    )

    component
  end

  # A ledger failure (E2EE currency change) arrives as `%{error: error}`.
  def action(:save_failed, %{error: _error}, component),
    do: put_state(component, :general_error, "Couldn't save the currency.")

  def action(:save_failed, %{errors: errors}, component) do
    put_state(component,
      display_name_error: Map.get(errors, :display_name),
      ws_name_error: Map.get(errors, :workspace_name),
      general_error: Map.get(errors, :general)
    )
  end

  def action(:share, _params, component) do
    email = component.state.share_email

    component
    |> put_state(:share_email, "")
    |> put_command(:share_workspace, email: email)
  end

  # --- commands (server) ---------------------------------------------------

  def command(:save_settings, params, server) do
    user = Context.user(server)
    workspace = Context.workspace(server)

    attrs = %{
      "display_name" => params.display_name,
      "workspace_name" => params.workspace_name,
      "currency" => params.currency
    }

    case AccountOps.save_settings(user, workspace, attrs) do
      {:ok, _snapshot_or_nil} ->
        snapshot =
          case Context.load(server) do
            {:ok, snapshot} -> snapshot
            {:error, :e2ee_locked} -> nil
          end

        put_action(server,
          name: :account_changed,
          target: "page",
          params: %{
            account: Context.account(server),
            snapshot: snapshot,
            modal: nil,
            notice: "Settings saved."
          }
        )

      {:error, errors} ->
        put_action(server, :save_failed, errors: errors)
    end
  end

  def command(:save_account, params, server) do
    user = Context.user(server)
    workspace = Context.workspace(server)

    # No "currency": that is vault data, saved in the browser.
    attrs = %{
      "display_name" => params.display_name,
      "workspace_name" => params.workspace_name
    }

    case AccountOps.save_settings(user, workspace, attrs) do
      {:ok, _} -> put_action(server, :account_saved, account: Context.account(server))
      {:error, errors} -> put_action(server, :save_failed, errors: errors)
    end
  end

  def command(:share_workspace, %{email: email}, server) do
    user = Context.user(server)
    workspace = Context.workspace(server)

    extra =
      case AccountOps.share_workspace(user, workspace, email) do
        {:ok, notice} -> %{notice: notice}
        {:error, error} -> %{error: error}
      end

    refresh_modal(server, user, workspace, extra)
  end

  def command(:cancel_invitation, %{id: id}, server) do
    user = Context.user(server)
    workspace = Context.workspace(server)
    AccountOps.cancel_invitation(user, workspace, id)
    refresh_modal(server, user, workspace, %{})
  end

  def command(:remove_member, %{id: id}, server) do
    user = Context.user(server)
    workspace = Context.workspace(server)
    AccountOps.remove_member(user, workspace, id)
    refresh_modal(server, user, workspace, %{})
  end

  defp refresh_modal(server, user, workspace, extra) do
    modal = AccountOps.settings_modal(user, workspace, extra)
    put_action(server, name: :open_modal, target: "page", params: %{modal: modal})
  end
end
