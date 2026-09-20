defmodule DebtReliefTrackerWeb.AdminLive do
  @moduledoc """
  Site-wide admin console: mailer/site identity settings, and the sent-email
  log with resend. Gated by `DebtReliefTrackerWeb.UserAuth`'s
  `:require_admin_scope` on_mount. A deliberate exception to "everything
  lives in DashboardLive" (CLAUDE.md) -- this is a site-config surface, not a
  debt/payment feature.
  """

  use DebtReliefTrackerWeb, :live_view

  alias DebtReliefTracker.{Accounts, Mailer, Settings}
  alias DebtReliefTracker.Settings.SiteSetting

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:site_settings, Settings.get_site_settings())
     |> assign(:mailer_configured?, Mailer.configured?())
     |> stream(:sent_emails, Accounts.list_sent_emails())}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    tab = if params["tab"] == "emails", do: :emails, else: :settings

    socket =
      socket
      |> assign(:tab, tab)
      |> assign(:form, to_form(SiteSetting.changeset(socket.assigns.site_settings, %{})))

    {:noreply, socket}
  end

  @impl true
  def handle_event("validate", %{"site_setting" => params}, socket) do
    form =
      socket.assigns.site_settings
      |> SiteSetting.changeset(params)
      |> Map.put(:action, :validate)
      |> to_form()

    {:noreply, assign(socket, :form, form)}
  end

  def handle_event("save", %{"site_setting" => params}, socket) do
    case Settings.update_site_settings(socket.assigns.site_settings, params) do
      {:ok, site_settings} ->
        {:noreply,
         socket
         |> assign(:site_settings, site_settings)
         |> assign(:form, to_form(SiteSetting.changeset(site_settings, %{})))
         |> put_flash(:info, "Settings saved.")}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}
    end
  end

  def handle_event("resend", %{"id" => id}, socket) do
    sent_email = Accounts.get_sent_email!(id)

    socket =
      case Accounts.resend_email(sent_email) do
        {:ok, :ok} ->
          put_flash(socket, :info, "Resent to #{sent_email.to}.")

        {:error, :gone} ->
          put_flash(socket, :error, "Couldn't resend -- the related data no longer exists.")
      end

    {:noreply, stream(socket, :sent_emails, Accounts.list_sent_emails(), reset: true)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <.header>
        Admin
        <:subtitle>Site settings and the sent-email log.</:subtitle>
        <:actions>
          <.link navigate={~p"/"} class="btn btn-ghost btn-sm">← Dashboard</.link>
        </:actions>
      </.header>

      <div class="tabs tabs-border mb-4">
        <.link patch={~p"/admin?tab=settings"} class={["tab", @tab == :settings && "tab-active"]}>
          Settings
        </.link>
        <.link patch={~p"/admin?tab=emails"} class={["tab", @tab == :emails && "tab-active"]}>
          Emails
        </.link>
      </div>

      <div :if={@tab == :settings}>
        <.form for={@form} id="admin-settings-form" phx-change="validate" phx-submit="save">
          <.input field={@form[:site_name]} type="text" label="Site name" />
          <.input field={@form[:from_name]} type="text" label="From name" />
          <.input field={@form[:from_email]} type="text" label="From email" />
          <.input
            field={@form[:welcome_emails_enabled]}
            type="checkbox"
            label="Send welcome emails"
          />
          <.button type="submit" class="btn btn-primary">Save</.button>
        </.form>
      </div>

      <div :if={@tab == :emails}>
        <div
          :if={!@mailer_configured?}
          id="mailer-not-configured-warning"
          role="alert"
          class="alert alert-warning mb-4"
        >
          <.icon name="hero-exclamation-triangle" class="size-5" />
          <span>
            No email provider is configured -- mail is only captured locally at
            <code>/dev/mailbox</code>
            and never actually delivered. Set <code>RESEND_API_KEY</code>
            (see the README's "Email" section) to send real email.
          </span>
        </div>

        <.table
          id="sent-emails"
          rows={@streams.sent_emails}
          row_item={fn {_id, sent_email} -> sent_email end}
        >
          <:col :let={sent_email} label="To">{sent_email.to}</:col>
          <:col :let={sent_email} label="Template">{sent_email.template}</:col>
          <:col :let={sent_email} label="Status">{sent_email.status}</:col>
          <:col :let={sent_email} label="Sent at">
            {Calendar.strftime(sent_email.inserted_at, "%b %d, %Y %I:%M %p")}
          </:col>
          <:action :let={sent_email}>
            <.button phx-click="resend" phx-value-id={sent_email.id} class="btn btn-ghost btn-sm">
              Resend
            </.button>
          </:action>
        </.table>
      </div>
    </Layouts.app>
    """
  end
end
