defmodule DebtReliefTrackerWeb.Holo.Components.HeaderBar do
  @moduledoc """
  Top bar: workspace name/switcher, settings button, user + log out, theme
  toggle. Port of the `<header>` in `DashboardLive.render/1`.

  Data comes from page props (`account`); changes go through commands that
  derive the user and workspace from `Holo.Context`, never from params:

    * `open_settings` -- loads the settings modal's server-only data
      (ownership, name editability, members, invitations) and opens it
    * `switch_workspace` -- remembers the choice in the session and reloads
      the snapshot + account
    * `set_theme` -- saves the theme to the account (the browser applies it
      immediately through `assets/js/holo_account.js`)
    * log out -- a real `POST /auth/logout` with a CSRF token minted by
      `Holo.Csrf` (see `action(:submit_logout, ...)`)
  """

  use Hologram.Component
  use Hologram.JS

  alias DebtReliefTrackerWeb.Holo.AccountOps
  alias DebtReliefTrackerWeb.Holo.Context
  alias DebtReliefTrackerWeb.Holo.Csrf

  middleware DebtReliefTrackerWeb.Holo.Auth

  prop :snapshot, :map
  prop :account, :map

  def template do
    ~HOLO"""
    <header
      id="app-header"
      class="navbar px-4 border-b border-base-300 gap-3 flex-wrap gap-y-2"
      data-saved-theme={@account.user.theme}
    >
      <div class="flex-1 flex items-center gap-3 min-w-0">
        <span id="workspace-name" class="font-semibold truncate min-w-0 sm:overflow-visible sm:text-clip sm:whitespace-normal">{@account.workspace.name}</span>

        {%if @account.oidc_enabled}
          {%if length(@account.workspaces) > 1}
            <select
              id="workspace-switcher"
              name="workspace_id"
              class="select select-sm max-w-[10rem] sm:max-w-none"
              value={@account.workspace.id}
              $change="switch_workspace"
            >
              {%for w <- @account.workspaces}
                <option value={w.id} selected={w.id == @account.workspace.id}>{w.name}</option>
              {/for}
            </select>
          {/if}
        {/if}

        <button
          id="settings-button"
          type="button"
          $click={command: :open_settings}
          class="btn btn-ghost btn-sm btn-circle min-h-9 min-w-9 sm:min-h-0 sm:min-w-0"
          aria-label="Settings"
        >
          <span class="hero-cog-6-tooth w-5 h-5"></span>
        </button>
      </div>

      {%if @account.oidc_enabled}
        <div id="user-menu" class="flex-none min-w-0 max-w-full flex items-center gap-2 text-sm">
          <span id="user-display-name" class="truncate max-w-[8rem] sm:max-w-none">{@account.user.display_name}</span>
          <button id="logout-button" type="button" $click="logout" class="btn btn-ghost btn-sm min-h-9 sm:min-h-0">
            Log out
          </button>
        </div>
      {/if}

      <div class="flex-none">
        <div
          id="theme-toggle"
          class="card relative flex flex-row items-center border-2 border-base-300 bg-base-300 rounded-full"
        >
          <div class="absolute w-1/3 h-full rounded-full border-1 border-base-200 bg-base-100 brightness-200 left-0 [[data-theme=light]_&]:left-1/3 [[data-theme=dark]_&]:left-2/3 transition-[left]"></div>

          <button
            id="theme-system"
            type="button"
            class="flex p-2 cursor-pointer w-1/3"
            data-phx-theme="system"
            aria-label="System theme"
            $click={:set_theme, theme: "system"}
          >
            <span class="hero-computer-desktop-micro size-4 opacity-75 hover:opacity-100"></span>
          </button>

          <button
            id="theme-light"
            type="button"
            class="flex p-2 cursor-pointer w-1/3"
            data-phx-theme="light"
            aria-label="Light theme"
            $click={:set_theme, theme: "light"}
          >
            <span class="hero-sun-micro size-4 opacity-75 hover:opacity-100"></span>
          </button>

          <button
            id="theme-dark"
            type="button"
            class="flex p-2 cursor-pointer w-1/3"
            data-phx-theme="dark"
            aria-label="Dark theme"
            $click={:set_theme, theme: "dark"}
          >
            <span class="hero-moon-micro size-4 opacity-75 hover:opacity-100"></span>
          </button>
        </div>
      </div>
    </header>
    """
  end

  # --- actions (client) ----------------------------------------------------

  def action(:switch_workspace, %{event: %{value: workspace_id}}, component),
    do: put_command(component, :switch_workspace, workspace_id: workspace_id)

  # Apply instantly in the browser, then save to the account.
  def action(:set_theme, %{theme: theme}, component) do
    JS.call(:HoloAccount, :setTheme, [theme])
    put_command(component, :save_theme, theme: theme)
  end

  def action(:logout, _params, component), do: put_command(component, :logout_token)

  # `/auth/logout` is a :browser-pipeline POST route, so it needs a real form
  # POST with a CSRF token -- done by the JS facade, not a Hologram form.
  def action(:submit_logout, %{token: token}, component) do
    JS.call(:HoloAccount, :postForm, ["/auth/logout", %{"_csrf_token" => token}])
    component
  end

  # --- commands (server) ---------------------------------------------------

  def command(:open_settings, _params, server) do
    modal = AccountOps.settings_modal(Context.user(server), Context.workspace(server))
    put_action(server, name: :open_modal, target: "page", params: %{modal: modal})
  end

  def command(:switch_workspace, %{workspace_id: workspace_id}, server) do
    case AccountOps.switchable_workspace_id(Context.user(server), workspace_id) do
      nil ->
        server

      id ->
        server = put_session(server, :workspace_id, id)
        {:ok, snapshot} = Context.load(server)

        put_action(server,
          name: :account_changed,
          target: "page",
          params: %{account: Context.account(server), snapshot: snapshot, modal: nil}
        )
    end
  end

  def command(:save_theme, %{theme: theme}, server) do
    case AccountOps.save_theme(Context.user(server), theme) do
      :ok ->
        put_action(server,
          name: :account_updated,
          target: "page",
          params: %{account: Context.account(server)}
        )

      :error ->
        server
    end
  end

  def command(:logout_token, _params, server) do
    {token, server} = Csrf.issue(server)
    put_action(server, :submit_logout, token: token)
  end
end
