defmodule DebtReliefTrackerWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use DebtReliefTrackerWeb, :html

  alias DebtReliefTracker.Accounts
  alias DebtReliefTrackerWeb.OIDC

  @liberapay_url "https://liberapay.com/DebtReliefTracker/"
  @ko_fi_url "https://ko-fi.com/calonmerc"

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates "layouts/*"

  @doc """
  Renders your app layout.

  This function is typically invoked from every template,
  and it often contains your application menu, sidebar,
  or similar.

  ## Examples

      <Layouts.app flash={@flash}>
        <h1>Content</h1>
      </Layouts.app>

  """
  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :current_scope, :map,
    default: nil,
    doc: "the current [scope](https://hexdocs.pm/phoenix/scopes.html)"

  attr :full_width, :boolean,
    default: false,
    doc:
      "renders a full-viewport-height layout with no nav chrome/max-width, for dashboard-style pages"

  attr :max_width, :string,
    default: "max-w-2xl",
    doc: "Tailwind max-width class for the centered content column (non-full-width only)"

  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <%= if @full_width do %>
      <div class="min-h-screen flex flex-col sm:h-screen sm:overflow-hidden" data-theme-scope>
        {render_slot(@inner_block)}
        <.flash_group flash={@flash} />
        <.app_footer current_scope={@current_scope} />
      </div>
    <% else %>
      <header class="navbar px-4 sm:px-6 lg:px-8 border-b border-base-300">
        <div class="flex-1">
          <.link navigate={~p"/"} class="font-semibold">Debt Relief Tracker</.link>
        </div>
        <div class="flex-none">
          <.theme_toggle />
        </div>
      </header>

      <main class="px-4 py-10 sm:px-6 lg:px-8">
        <div class={["mx-auto space-y-4", @max_width]}>
          {render_slot(@inner_block)}
        </div>
      </main>

      <.flash_group flash={@flash} />
      <.app_footer current_scope={@current_scope} />
    <% end %>
    """
  end

  attr :current_scope, :map, default: nil

  defp app_footer(assigns) do
    ~H"""
    <footer
      id="app-footer"
      class="shrink-0 min-h-10 py-2 flex flex-wrap items-center justify-center gap-x-2 gap-y-1 border-t border-base-300 text-sm text-base-content/70 sm:h-10 sm:py-0 sm:gap-2"
    >
      <span>Debt Relief Tracker</span>
      <span aria-hidden="true">·</span>
      <.link
        href="https://github.com/Debt-Relief-Tracker/Tracker"
        target="_blank"
        rel="noopener noreferrer"
        class="link link-hover"
      >
        GitHub
      </.link>
      <span aria-hidden="true">·</span>
      <.link
        href="https://github.com/Debt-Relief-Tracker/Tracker/blob/main/LICENSE"
        target="_blank"
        rel="noopener noreferrer"
        class="link link-hover"
      >
        MIT License
      </.link>
      <span aria-hidden="true">·</span>
      <button
        type="button"
        id="donate-link"
        class="link link-hover"
        phx-click={show_donate()}
      >
        Donate
      </button>
      <%= if not OIDC.enabled?() or Accounts.admin?(@current_scope) do %>
        <span aria-hidden="true">·</span>
        <.link navigate={~p"/admin"} class="link link-hover">Admin</.link>
      <% end %>
      <.donate_modal />
    </footer>
    """
  end

  # Opened/closed purely client-side (JS.show/JS.hide) since the footer is
  # shared by every LiveView and there's no server state to track.
  defp donate_modal(assigns) do
    assigns = assign(assigns, liberapay_url: @liberapay_url, ko_fi_url: @ko_fi_url)

    ~H"""
    <.modal id="donate-modal" hidden on_cancel={hide_donate()}>
      <div class="space-y-4 text-base-content">
        <div class="flex items-center justify-between gap-2">
          <h2 class="text-lg font-semibold">Ways to donate</h2>
          <button
            type="button"
            id="donate-modal-close"
            class="btn btn-ghost btn-sm btn-square"
            aria-label="Close"
            phx-click={hide_donate()}
          >
            <.icon name="hero-x-mark" class="size-5" />
          </button>
        </div>
        <p class="text-base-content/70">
          GitHub Sponsors is pending approval. In the meantime, you can donate via Liberapay or Ko-fi.
        </p>
        <div class="grid grid-cols-1 gap-3 sm:grid-cols-3">
          <div
            id="donate-github-sponsors"
            aria-disabled="true"
            class="rounded-lg border border-dashed border-base-300 p-4 flex items-center justify-center text-center text-sm text-base-content/40"
          >
            GitHub Sponsors — coming soon
          </div>
          <a
            id="donate-liberapay"
            href={@liberapay_url}
            target="_blank"
            rel="noopener noreferrer"
            class="rounded-lg border border-primary/30 p-4 flex items-center justify-center text-center font-semibold text-primary hover:bg-primary/5 transition-colors"
          >
            Liberapay
          </a>
          <a
            id="donate-ko-fi"
            href={@ko_fi_url}
            target="_blank"
            rel="noopener noreferrer"
            class="rounded-lg border border-primary/30 p-4 flex items-center justify-center text-center font-semibold text-primary hover:bg-primary/5 transition-colors"
          >
            Ko-fi
          </a>
        </div>
      </div>
    </.modal>
    """
  end

  defp show_donate(js \\ %JS{}), do: JS.show(js, to: "#donate-modal", display: "flex")
  defp hide_donate(js \\ %JS{}), do: JS.hide(js, to: "#donate-modal")

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title={gettext("We can't find the internet")}
        phx-disconnected={show(".phx-client-error #client-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title={gettext("Something went wrong!")}
        phx-disconnected={show(".phx-server-error #server-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end

  @doc """
  Provides dark vs light theme toggle based on themes defined in app.css.

  See <head> in root.html.heex which applies the theme before page load.
  """
  def theme_toggle(assigns) do
    ~H"""
    <div class="card relative flex flex-row items-center border-2 border-base-300 bg-base-300 rounded-full">
      <div class="absolute w-1/3 h-full rounded-full border-1 border-base-200 bg-base-100 brightness-200 left-0 [[data-theme=light]_&]:left-1/3 [[data-theme=dark]_&]:left-2/3 transition-[left]" />

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="system"
      >
        <.icon name="hero-computer-desktop-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="light"
      >
        <.icon name="hero-sun-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="dark"
      >
        <.icon name="hero-moon-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>
    </div>
    """
  end
end
