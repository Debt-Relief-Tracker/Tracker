defmodule DebtReliefTrackerWeb.AdminLive do
  @moduledoc """
  Site-wide admin console: mailer/site identity settings, a paginated user
  list (joined / last seen / last login, with a detail modal), the sent-email
  log with resend, the inbound support-email log, and API token management
  (docs/architecture/0006-support-api-and-tokens.md). Gated by
  `DebtReliefTrackerWeb.UserAuth`'s `:require_admin_scope` on_mount. A
  deliberate exception to "everything lives in DashboardLive" (CLAUDE.md) --
  this is a site-config surface, not a debt/payment feature.
  """

  use DebtReliefTrackerWeb, :live_view

  alias DebtReliefTracker.{Accounts, Mailer, Settings, Support}
  alias DebtReliefTracker.Accounts.ApiToken
  alias DebtReliefTracker.Settings.SiteSetting

  @per_page_options [10, 25, 50, 100]
  @default_per_page 25

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:site_settings, Settings.get_site_settings())
     |> assign(:mailer_configured?, Mailer.configured?())
     |> assign(:show_new_token_form, false)
     |> assign(:new_token, nil)
     |> assign(:token_form, to_form(ApiToken.changeset(%ApiToken{}, %{})))
     |> assign(:viewing_support_email, nil)
     |> assign(:viewing_user, nil)
     |> assign(:users_page, nil)
     |> assign(:per_page_options, @per_page_options)
     |> stream(:sent_emails, Accounts.list_sent_emails())
     |> stream(:support_emails, Support.list_support_emails())
     |> stream(:api_tokens, Accounts.list_api_tokens())}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    tab =
      case params["tab"] do
        "users" -> :users
        "emails" -> :emails
        "support_emails" -> :support_emails
        "tokens" -> :tokens
        _ -> :settings
      end

    socket =
      socket
      |> assign(:tab, tab)
      |> assign(:form, to_form(SiteSetting.changeset(socket.assigns.site_settings, %{})))
      |> maybe_load_users(tab, params)

    {:noreply, socket}
  end

  defp maybe_load_users(socket, :users, params) do
    users_page =
      Accounts.list_users_for_admin(
        page: parse_positive_int(params["page"], 1),
        per_page: parse_per_page(params["per_page"])
      )

    socket
    |> assign(:users_page, users_page)
    |> stream(:users, users_page.entries, reset: true)
  end

  defp maybe_load_users(socket, _tab, _params), do: socket

  defp parse_positive_int(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} when int > 0 -> int
      _ -> default
    end
  end

  defp parse_positive_int(_value, default), do: default

  defp parse_per_page(value) do
    per_page = parse_positive_int(value, @default_per_page)
    if per_page in @per_page_options, do: per_page, else: @default_per_page
  end

  defp users_path(page, per_page),
    do: ~p"/admin?#{[tab: "users", page: page, per_page: per_page]}"

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

  def handle_event("set_per_page", %{"per_page" => per_page}, socket) do
    {:noreply, push_patch(socket, to: users_path(1, parse_per_page(per_page)))}
  end

  def handle_event("view_user", %{"id" => id}, socket) do
    {:noreply, assign(socket, :viewing_user, Accounts.get_user_for_admin!(id))}
  end

  def handle_event("close_user", _params, socket) do
    {:noreply, assign(socket, :viewing_user, nil)}
  end

  def handle_event("view_support_email", %{"id" => id}, socket) do
    {:noreply, assign(socket, :viewing_support_email, Support.get_support_email!(id))}
  end

  def handle_event("close_support_email", _params, socket) do
    {:noreply, assign(socket, :viewing_support_email, nil)}
  end

  def handle_event("new_token", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_new_token_form, true)
     |> assign(:token_form, to_form(ApiToken.changeset(%ApiToken{}, %{})))}
  end

  def handle_event("cancel_new_token", _params, socket) do
    {:noreply, assign(socket, :show_new_token_form, false)}
  end

  def handle_event("dismiss_new_token", _params, socket) do
    {:noreply, assign(socket, :new_token, nil)}
  end

  def handle_event("validate_token", %{"api_token" => params}, socket) do
    form =
      %ApiToken{}
      |> ApiToken.changeset(normalize_token_params(params))
      |> Map.put(:action, :validate)
      |> to_form()

    {:noreply, assign(socket, :token_form, form)}
  end

  def handle_event("create_token", %{"api_token" => params}, socket) do
    created_by = socket.assigns.current_scope.user

    case Accounts.create_api_token(normalize_token_params(params), created_by) do
      {:ok, raw_token, api_token} ->
        {:noreply,
         socket
         |> assign(:new_token, {raw_token, api_token})
         |> assign(:show_new_token_form, false)
         |> assign(:token_form, to_form(ApiToken.changeset(%ApiToken{}, %{})))
         |> stream(:api_tokens, Accounts.list_api_tokens(), reset: true)}

      {:error, changeset} ->
        {:noreply, assign(socket, :token_form, to_form(changeset))}
    end
  end

  def handle_event("revoke_token", %{"id" => id}, socket) do
    {:ok, _} = id |> Accounts.get_api_token!() |> Accounts.revoke_api_token()

    {:noreply,
     socket
     |> put_flash(:info, "Token revoked.")
     |> stream(:api_tokens, Accounts.list_api_tokens(), reset: true)}
  end

  # Checkboxes named "api_token[scopes][]" submit every checked value under
  # one key, plus an empty-string sentinel from the hidden fallback field
  # (ensures the key exists at all when nothing's checked) -- drop it here.
  defp normalize_token_params(params) do
    Map.update(params, "scopes", [], fn scopes -> Enum.reject(List.wrap(scopes), &(&1 == "")) end)
  end

  # Label for the IdP behind an OIDC `sub` claim (`"<connection>|<id>"` for
  # Auth0); `nil` is no-auth mode's implicit local user (ADR 0002).
  defp provider_label(nil), do: "Local (no-auth)"
  defp provider_label("auth0|" <> _), do: "Auth0"
  defp provider_label("google-oauth2|" <> _), do: "Google"

  defp provider_label(subject) do
    case String.split(subject, "|", parts: 2) do
      [connection, _id] -> connection
      _ -> "OIDC"
    end
  end

  defp workspace_summary(user) do
    owned = Enum.count(user.workspace_members, &(&1.role == :owner))
    shared = length(user.workspace_members) - owned
    "#{owned} owned · #{shared} shared"
  end

  defp format_datetime(nil), do: "Never"
  defp format_datetime(datetime), do: Calendar.strftime(datetime, "%b %d, %Y %I:%M %p")

  # No-auth mode's implicit user never logs in, so "Never" would mislead.
  defp format_last_login(%{external_subject: nil}), do: "N/A (no-auth)"
  defp format_last_login(user), do: format_datetime(user.last_login_at)

  defp page_range(%{total: 0}), do: "0"

  defp page_range(%{page: page, per_page: per_page, total: total}) do
    first = (page - 1) * per_page + 1
    "#{first}–#{min(first + per_page - 1, total)}"
  end

  @impl true
  def render(assigns) do
    ~H"""
    <%!-- Wider than the default max-w-2xl -- the Users/Emails tables have
         many columns and get cramped on large displays. --%>
    <Layouts.app flash={@flash} current_scope={@current_scope} max_width="max-w-7xl">
      <.header>
        Admin
        <:subtitle>Site settings, users, email logs, and API tokens.</:subtitle>
        <:actions>
          <.link navigate={~p"/"} class="btn btn-ghost btn-sm">← Dashboard</.link>
        </:actions>
      </.header>

      <div class="tabs tabs-border mb-4 flex-nowrap overflow-x-auto">
        <.link patch={~p"/admin?tab=settings"} class={["tab", @tab == :settings && "tab-active"]}>
          Settings
        </.link>
        <.link patch={~p"/admin?tab=users"} class={["tab", @tab == :users && "tab-active"]}>
          Users
        </.link>
        <.link patch={~p"/admin?tab=emails"} class={["tab", @tab == :emails && "tab-active"]}>
          Emails
        </.link>
        <.link
          patch={~p"/admin?tab=support_emails"}
          class={["tab", @tab == :support_emails && "tab-active"]}
        >
          Support Emails
        </.link>
        <.link patch={~p"/admin?tab=tokens"} class={["tab", @tab == :tokens && "tab-active"]}>
          API Tokens
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

      <div :if={@tab == :users}>
        <.table id="users" rows={@streams.users} row_item={fn {_id, user} -> user end}>
          <:col :let={user} label="Name">
            <span class="whitespace-nowrap">{user.display_name}</span>
            <span :if={user.is_admin} class="badge badge-primary badge-sm ml-1">Admin</span>
          </:col>
          <:col :let={user} label="Email">{user.email || "—"}</:col>
          <:col :let={user} label="Provider">{provider_label(user.external_subject)}</:col>
          <:col :let={user} label="Workspaces">
            <span class="whitespace-nowrap">{workspace_summary(user)}</span>
          </:col>
          <:col :let={user} label="Joined">
            {Calendar.strftime(user.inserted_at, "%b %d, %Y")}
          </:col>
          <:col :let={user} label="Last seen">{format_datetime(user.last_seen_at)}</:col>
          <:col :let={user} label="Last login">{format_last_login(user)}</:col>
          <:action :let={user}>
            <.button
              id={"view-user-#{user.id}"}
              phx-click="view_user"
              phx-value-id={user.id}
              class="btn btn-ghost btn-sm"
            >
              View
            </.button>
          </:action>
        </.table>

        <div
          id="users-pager"
          class="mt-4 flex flex-col gap-2 sm:flex-row sm:items-center sm:justify-between"
        >
          <p class="text-sm text-base-content/70">
            Showing {page_range(@users_page)} of {@users_page.total}
          </p>
          <div class="flex flex-wrap items-center gap-2">
            <.form
              for={to_form(%{"per_page" => @users_page.per_page})}
              id="users-per-page-form"
              phx-change="set_per_page"
              class="flex items-center gap-2"
            >
              <span class="text-sm whitespace-nowrap">Per page</span>
              <.input
                type="select"
                id="users-per-page"
                name="per_page"
                value={@users_page.per_page}
                options={@per_page_options}
                class="select select-sm w-20"
              />
            </.form>
            <.link
              id="users-prev"
              patch={users_path(@users_page.page - 1, @users_page.per_page)}
              class={["btn btn-sm", @users_page.page <= 1 && "btn-disabled"]}
            >
              Prev
            </.link>
            <span class="text-sm whitespace-nowrap">
              Page {@users_page.page} of {@users_page.total_pages}
            </span>
            <.link
              id="users-next"
              patch={users_path(@users_page.page + 1, @users_page.per_page)}
              class={["btn btn-sm", @users_page.page >= @users_page.total_pages && "btn-disabled"]}
            >
              Next
            </.link>
          </div>
        </div>

        <.modal :if={@viewing_user} id="user-detail-modal" on_cancel="close_user">
          <.header>
            {@viewing_user.display_name}
            <:subtitle>{@viewing_user.email || "No email on file"}</:subtitle>
          </.header>
          <dl class="grid grid-cols-1 gap-x-4 gap-y-2 text-sm mb-6 sm:grid-cols-[auto_1fr]">
            <dt class="font-semibold">Provider</dt>
            <dd>{provider_label(@viewing_user.external_subject)}</dd>
            <dt class="font-semibold">Admin</dt>
            <dd>{if @viewing_user.is_admin, do: "Yes", else: "No"}</dd>
            <dt class="font-semibold">Joined</dt>
            <dd>{format_datetime(@viewing_user.inserted_at)}</dd>
            <dt class="font-semibold">Last seen</dt>
            <dd>{format_datetime(@viewing_user.last_seen_at)}</dd>
            <dt class="font-semibold">Last login</dt>
            <dd>{format_last_login(@viewing_user)}</dd>
          </dl>

          <p class="font-semibold mb-1">Workspaces</p>
          <p :if={@viewing_user.workspace_members == []} class="text-sm text-base-content/70">
            Not a member of any workspace.
          </p>
          <.table
            :if={@viewing_user.workspace_members != []}
            id="user-detail-workspaces"
            rows={@viewing_user.workspace_members}
          >
            <:col :let={member} label="Workspace">{member.workspace.name}</:col>
            <:col :let={member} label="Role">{member.role}</:col>
            <:col :let={member} label="Since">
              {Calendar.strftime(member.inserted_at, "%b %d, %Y")}
            </:col>
          </.table>
        </.modal>
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

      <div :if={@tab == :support_emails}>
        <p class="text-sm text-base-content/70 mb-4">
          Inbound emails logged via <code>POST /api/support_emails</code>
          -- see <.link navigate={~p"/api/swaggerui"} class="link">/api/swaggerui</.link>.
        </p>

        <.table
          id="support-emails"
          rows={@streams.support_emails}
          row_item={fn {_id, support_email} -> support_email end}
        >
          <:col :let={support_email} label="From">{support_email.from}</:col>
          <:col :let={support_email} label="To">{support_email.to}</:col>
          <:col :let={support_email} label="Subject">{support_email.subject}</:col>
          <:col :let={support_email} label="Received at">
            {Calendar.strftime(support_email.received_at, "%b %d, %Y %I:%M %p")}
          </:col>
          <:action :let={support_email}>
            <.button
              phx-click="view_support_email"
              phx-value-id={support_email.id}
              class="btn btn-ghost btn-sm"
            >
              View
            </.button>
          </:action>
        </.table>

        <.modal :if={@viewing_support_email} on_cancel="close_support_email">
          <.header>{@viewing_support_email.subject}</.header>
          <p class="text-sm text-base-content/70 mb-4">
            From {@viewing_support_email.from} to {@viewing_support_email.to} -- received {Calendar.strftime(
              @viewing_support_email.received_at,
              "%b %d, %Y %I:%M %p"
            )}
          </p>
          <div class="whitespace-pre-wrap mb-4">{@viewing_support_email.body}</div>
          <div :if={@viewing_support_email.metadata != %{}}>
            <p class="font-semibold mb-1">Metadata</p>
            <pre class="bg-base-200 rounded p-3 text-sm overflow-x-auto"><code>{Jason.encode!(@viewing_support_email.metadata, pretty: true)}</code></pre>
          </div>
        </.modal>
      </div>

      <div :if={@tab == :tokens}>
        <.button phx-click="new_token" class="btn btn-primary btn-sm mb-4">+ New token</.button>

        <.table id="api-tokens" rows={@streams.api_tokens} row_item={fn {_id, t} -> t end}>
          <:col :let={t} label="Name">{t.name}</:col>
          <:col :let={t} label="Scopes">{Enum.join(t.scopes, ", ")}</:col>
          <:col :let={t} label="Token">•••• {t.last_four}</:col>
          <:col :let={t} label="Last used">
            {if t.last_used_at,
              do: Calendar.strftime(t.last_used_at, "%b %d, %Y %I:%M %p"),
              else: "Never"}
          </:col>
          <:col :let={t} label="Status">
            <span class={["badge", if(ApiToken.revoked?(t), do: "badge-ghost", else: "badge-success")]}>
              {if ApiToken.revoked?(t), do: "Revoked", else: "Active"}
            </span>
          </:col>
          <:action :let={t}>
            <.button
              :if={!ApiToken.revoked?(t)}
              phx-click="revoke_token"
              phx-value-id={t.id}
              data-confirm="Revoke this token? Anything using it will stop working immediately."
              class="btn btn-ghost btn-sm"
            >
              Revoke
            </.button>
          </:action>
        </.table>

        <.modal :if={@show_new_token_form} on_cancel="cancel_new_token">
          <.header>New API token</.header>
          <.form
            for={@token_form}
            id="new-token-form"
            phx-change="validate_token"
            phx-submit="create_token"
          >
            <.input
              field={@token_form[:name]}
              type="text"
              label="Name"
              placeholder="e.g. Support inbox webhook"
            />
            <fieldset class="fieldset mb-2">
              <legend class="label mb-1">Scopes</legend>
              <input type="hidden" name="api_token[scopes][]" value="" />
              <label :for={scope <- ApiToken.known_scopes()} class="label gap-2">
                <input
                  type="checkbox"
                  name="api_token[scopes][]"
                  value={scope}
                  checked={scope in @token_form[:scopes].value}
                  class="checkbox checkbox-sm"
                />
                {scope}
              </label>
              <p :for={msg <- @token_form[:scopes].errors} class="mt-1.5 text-sm text-error">
                {translate_error(msg)}
              </p>
            </fieldset>
            <.button type="submit" class="btn btn-primary">Create token</.button>
          </.form>
        </.modal>

        <.modal :if={@new_token} on_cancel="dismiss_new_token">
          <.header>Token created</.header>
          <p class="mb-2">Copy this token now -- it won't be shown again.</p>
          <code class="block p-3 bg-base-200 rounded break-all">{elem(@new_token, 0)}</code>
          <.button phx-click="dismiss_new_token" class="btn btn-primary mt-4">Done</.button>
        </.modal>
      </div>
    </Layouts.app>
    """
  end
end
