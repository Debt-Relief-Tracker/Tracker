defmodule DebtReliefTrackerWeb.Holo.Components.RetirementModal do
  @moduledoc """
  Retirement onboarding roster + add/edit profile form. The page renders this
  for modal types `:retirement_onboarding` (the household roster) and
  `:retirement_profile_form` (add/edit one person); the page's `modal` map
  only carries the `type`, the form's own state lives here.

  Other components open the roster with the page action
  `:open_modal %{modal: %{type: :retirement_onboarding}}` (see
  `onboarding_modal/0`).

  Which screen shows is this component's own `screen` state (`:roster` |
  `:form`): a Hologram handler can queue only one follow-up action, so
  "save, refresh the snapshot and go back to the roster" is done locally
  rather than by switching the page's modal type back and forth.

  Ported from `DashboardLive`'s `open_retirement_onboarding`,
  `open_add_retirement_profile`, `cancel_retirement_profile_form`,
  `validate/add/edit/update/delete_retirement_profile` and
  `dismiss_retirement_prompt` handlers. Validation runs client-side
  (`Holo.RetirementForm`, same messages as the changeset) on submit, and
  again on the server inside `Storage`.

  Component state: `form` (strings), `errors` (`%{field => [message]}`),
  `screen`, `source` (`"member"` | `"manual"`, add flow), `members` (eligible
  `%{id, display_name}` for the picker), `editing_profile_id`,
  `editing_manual`.
  """

  use Hologram.Component

  alias DebtReliefTracker.Accounts
  alias DebtReliefTrackerWeb.Holo.Context
  alias DebtReliefTrackerWeb.Holo.RetirementForm

  middleware DebtReliefTrackerWeb.Holo.Auth

  prop :snapshot, :map
  prop :account, :map
  prop :modal, :map, default: nil

  @doc "The page modal map that opens the roster."
  def onboarding_modal, do: %{type: :retirement_onboarding}

  def init(_props, component) do
    reset_form(component)
  end

  # --- template ------------------------------------------------------------

  def template do
    ~HOLO"""
    <div
      id="retirement-modal"
      class="fixed inset-0 bg-black/50 flex items-center justify-center p-4 sm:p-0 z-50"
    >
      <window $key_down.escape="escape" />
      <div class="bg-base-100 rounded-lg p-4 sm:p-6 w-full max-w-2xl max-h-[90vh] overflow-y-auto">
        {%if @screen == :roster}
          <h2 class="font-semibold text-lg mb-4">Plan your household's retirement</h2>
          <p class="text-sm opacity-70 mb-4">
            See how paying off debt sooner grows your household's retirement savings, by redirecting
            more of everyone's income into investing once you're debt-free.
          </p>

          {%if @snapshot.retirement_profiles == []}
            <p id="retirement-empty" class="text-sm opacity-70 mb-4">
              No one in the household has a retirement profile yet.
            </p>
          {%else}
            <ul id="retirement-profile-list" class="flex flex-col gap-2 mb-4">
              {%for profile <- @snapshot.retirement_profiles}
                <li id={"retirement-profile-#{profile.id}"} class="flex items-center justify-between text-sm">
                  <span>
                    {profile.display_name} -- retiring at {profile.retirement_age} (currently {profile.current_age})
                  </span>
                  <div class="flex gap-2">
                    <button
                      type="button"
                      id={"edit-retirement-profile-#{profile.id}"}
                      class="btn btn-ghost btn-xs"
                      $click={:edit_profile, id: profile.id}
                    >
                      Edit
                    </button>
                    <button
                      type="button"
                      id={"delete-retirement-profile-#{profile.id}"}
                      class="btn btn-ghost btn-xs"
                      $click={:delete_profile, id: profile.id}
                    >
                      Remove
                    </button>
                  </div>
                </li>
              {/for}
            </ul>
          {/if}

          <button
            type="button"
            id="open-add-retirement-profile"
            class="btn btn-soft btn-sm w-full mb-4"
            $click="open_add_profile"
          >
            + Add person
          </button>

          <div class="flex justify-end gap-2 mt-2">
            {%if @snapshot.retirement_profiles == []}
              <button
                type="button"
                id="dismiss-retirement-prompt"
                class="btn btn-primary btn-soft"
                $click="dismiss_prompt"
              >
                Skip for now
              </button>
            {/if}
            <button
              type="button"
              id="close-retirement-modal"
              class="btn btn-primary btn-soft"
              $click={action: :close_modal, target: "page"}
            >
              Close
            </button>
          </div>
        {%else}
          <h2 class="font-semibold text-lg mb-4">
            {%if @editing_profile_id == nil}Add a person{%else}Edit retirement profile{/if}
          </h2>

          <form id="retirement-profile-form" class="flex flex-col gap-3" $submit="submit">
            {%for message <- Map.get(@errors, :base, [])}
              <p class="text-sm text-error">{message}</p>
            {/for}

            {%if @editing_profile_id == nil && @members != []}
              <div id="retirement-source" class="flex flex-wrap gap-x-4 gap-y-1 text-sm">
                <label class="flex items-center gap-1">
                  <input
                    type="radio"
                    name="source"
                    id="retirement-source-member"
                    value="member"
                    checked={@source == "member"}
                    $change={:set_source, source: "member"}
                  />
                  Existing member
                </label>
                <label class="flex items-center gap-1">
                  <input
                    type="radio"
                    name="source"
                    id="retirement-source-manual"
                    value="manual"
                    checked={@source == "manual"}
                    $change={:set_source, source: "manual"}
                  />
                  Someone without an account
                </label>
              </div>
            {/if}

            {%if @editing_profile_id == nil && @source == "member"}
              <div class="fieldset mb-2">
                <label>
                  <span class="label mb-1">Household member</span>
                  <select
                    id="retirement_profile_user_id"
                    name="user_id"
                    class="w-full select"
                    value={@form.user_id}
                    $change={:set_field, field: :user_id}
                  >
                    {%for member <- @members}
                      <option value={member.id} selected={member.id == @form.user_id}>{member.display_name}</option>
                    {/for}
                  </select>
                </label>
                {%for message <- Map.get(@errors, :user_id, [])}
                  <p class="mt-1.5 text-sm text-error">{message}</p>
                {/for}
              </div>
            {/if}

            {%if @source == "manual" || @editing_manual}
              <div class="fieldset mb-2">
                <label>
                  <span class="label mb-1">Name</span>
                  <input
                    type="text"
                    id="retirement_profile_name"
                    name="name"
                    class="w-full input"
                    value={@form.name}
                    $change={:set_field, field: :name}
                  />
                </label>
                {%for message <- Map.get(@errors, :name, [])}
                  <p class="mt-1.5 text-sm text-error">{message}</p>
                {/for}
              </div>
              <div class="fieldset mb-2">
                <label>
                  <span class="label mb-1 whitespace-normal">Email (optional -- links their account automatically if they sign in later)</span>
                  <input
                    type="email"
                    id="retirement_profile_claim_email"
                    name="claim_email"
                    class="w-full input"
                    value={@form.claim_email}
                    $change={:set_field, field: :claim_email}
                  />
                </label>
                {%for message <- Map.get(@errors, :claim_email, [])}
                  <p class="mt-1.5 text-sm text-error">{message}</p>
                {/for}
              </div>
            {/if}

            {%for {field, label, _kind} <- RetirementForm.numeric_fields()}
              <div class="fieldset mb-2">
                <label>
                  <span class="label mb-1 whitespace-normal">{label}</span>
                  <input
                    type="text"
                    inputmode="decimal"
                    id={"retirement_profile_#{field}"}
                    name={field}
                    class="w-full input"
                    value={Map.get(@form, field)}
                    $change={:set_field, field: field}
                  />
                </label>
                {%for message <- Map.get(@errors, field, [])}
                  <p class="mt-1.5 text-sm text-error">{message}</p>
                {/for}
              </div>
            {/for}

            <div class="flex justify-end gap-2 mt-2">
              <button
                type="button"
                id="cancel-retirement-profile-form"
                class="btn btn-primary btn-soft"
                $click="cancel_form"
              >
                Cancel
              </button>
              <button type="submit" id="save-retirement-profile" class="btn btn-primary">
                {%if @editing_profile_id == nil}Add person{%else}Save{/if}
              </button>
            </div>
          </form>
        {/if}
      </div>
    </div>
    """
  end

  # --- actions -------------------------------------------------------------

  # Esc: back out one screen, as the LiveView's modal `on_cancel` does.
  def action(:escape, _params, component) do
    case component.state.screen do
      :form -> reset_form(component)
      _ -> put_action(component, name: :close_modal, target: "page")
    end
  end

  # The members list is account data, so it comes from the server; the
  # members who already have a profile are dropped client-side from the
  # snapshot, which keeps working when profiles are not readable server-side.
  def action(:open_add_profile, _params, component) do
    put_command(component, :load_members)
  end

  def action(:members_loaded, %{members: members}, component) do
    profiled = Enum.map(component.props.snapshot.retirement_profiles, & &1.user_id)
    eligible = Enum.filter(members, fn member -> not Enum.member?(profiled, member.id) end)

    {source, user_id} =
      case eligible do
        [] -> {"manual", ""}
        [first | _rest] -> {"member", first.id}
      end

    component
    |> reset_form()
    |> put_state(:members, eligible)
    |> put_state(:source, source)
    |> put_state(:form, RetirementForm.blank(user_id))
    |> put_state(:screen, :form)
  end

  def action(:edit_profile, %{id: id}, component) do
    case Enum.find(component.props.snapshot.retirement_profiles, fn p -> p.id == id end) do
      nil ->
        component

      profile ->
        component
        |> reset_form()
        |> put_state(:editing_profile_id, profile.id)
        |> put_state(:editing_manual, profile.user_id == nil)
        |> put_state(:form, RetirementForm.from_profile(profile))
        |> put_state(:screen, :form)
    end
  end

  def action(:cancel_form, _params, component), do: reset_form(component)

  def action(:set_field, %{field: field, event: %{value: value}}, component) do
    component
    |> put_state([:form, field], value)
    |> put_state(:errors, Map.delete(component.state.errors, field))
  end

  # The source comes from the radio's own params, not the change event: for a
  # radio the event's `value` is not the option's string (the form then
  # showed neither the member picker nor the name field).
  def action(:set_source, %{source: source}, component) when source in ["member", "manual"] do
    current = component.state.form.user_id

    user_id =
      cond do
        current != "" -> current
        component.state.members == [] -> ""
        true -> hd(component.state.members).id
      end

    component
    |> put_state(:source, source)
    |> put_state([:form, :user_id], user_id)
    |> put_state(:errors, %{})
  end

  def action(:submit, _params, component) do
    state = component.state

    mode =
      case state.editing_profile_id do
        nil -> {:add, state.source}
        id -> {:update, id, state.editing_manual}
      end

    case RetirementForm.build_change(mode, state.form) do
      {:ok, change} ->
        component |> put_state(:errors, %{}) |> put_command(:save, change: change)

      {:error, errors} ->
        put_state(component, :errors, errors)
    end
  end

  def action(:save_failed, %{error: error}, component) do
    put_state(component, :errors, RetirementForm.errors_from(error))
  end

  # A command can queue only one follow-up action, so it targets this
  # component; going back to the roster is local state, and the fresh
  # snapshot is forwarded to the page here.
  def action(:saved, %{snapshot: snapshot}, component) do
    component
    |> reset_form()
    |> put_action(name: :snapshot_updated, target: "page", params: %{snapshot: snapshot})
  end

  def action(:delete_profile, %{id: id}, component) do
    put_command(component, :delete, id: id)
  end

  # The modal closes right away (that is what "Skip" means); the command's
  # single follow-up action delivers the snapshot with the flag set.
  def action(:dismiss_prompt, _params, component) do
    component
    |> put_command(:dismiss)
    |> put_action(name: :close_modal, target: "page")
  end

  # --- commands (server) -----------------------------------------------------

  # Confirmed members of the caller's workspace, for the "existing member" picker.
  def command(:load_members, _params, server) do
    members =
      server
      |> Context.workspace()
      |> Accounts.list_confirmed_members()
      |> Enum.map(fn member -> %{id: member.user.id, display_name: member.user.display_name} end)

    put_action(server, :members_loaded, members: members)
  end

  def command(:save, %{change: change}, server) do
    case Context.apply_change(server, change) do
      {:ok, snapshot} ->
        put_action(server, :saved, snapshot: snapshot)

      {:error, error} ->
        put_action(server, :save_failed, error: error)
    end
  end

  def command(:delete, %{id: id}, server) do
    case Context.apply_change(server, {:delete_retirement_profile, id}) do
      {:ok, snapshot} ->
        put_action(server, name: :snapshot_updated, target: "page", params: %{snapshot: snapshot})

      {:error, error} ->
        put_action(server, name: :change_failed, target: "page", params: %{error: error})
    end
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

  defp reset_form(component) do
    put_state(component,
      form: RetirementForm.blank(),
      errors: %{},
      source: "manual",
      members: [],
      editing_profile_id: nil,
      editing_manual: false,
      screen: :roster
    )
  end
end
