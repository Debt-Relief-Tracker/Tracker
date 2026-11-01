defmodule DebtReliefTrackerWeb.Holo.Components.DebtFormModal do
  @moduledoc """
  Add / edit debt modal (modal types `:add_debt`, `:edit_debt`). Port of
  `DashboardLive`'s `debt_form_modal`, `validate_debt`, `save_debt` and
  `delete_debt`.

  Form values are kept as text in `:form` (synchronized inputs); `:save`
  validates/converts them with `Holo.DebtLogic.debt_change/1` (dollars->cents
  by integer math), then a `Storage` change is sent by command.
  """

  use Hologram.Component

  alias DebtReliefTrackerWeb.Holo.Auth
  alias DebtReliefTrackerWeb.Holo.Components.DebtModalFrame
  alias DebtReliefTrackerWeb.Holo.DataPath
  alias DebtReliefTrackerWeb.Holo.DebtCommands
  alias DebtReliefTrackerWeb.Holo.DebtLogic

  middleware Auth

  prop :snapshot, :map
  prop :account, :map
  prop :modal, :map, default: nil
  prop :e2ee, :boolean, from_context: :e2ee

  def init(props, component), do: init_state(props, component)
  def init(props, component, _server), do: init_state(props, component)

  defp init_state(props, component) do
    debt = props.modal && DebtLogic.find_debt(props.snapshot, Map.get(props.modal, :debt_id))

    component
    |> put_state(:form, DebtLogic.debt_form(debt))
    |> put_state(:errors, %{})
    |> put_state(:confirm_delete, false)
  end

  def template do
    ~HOLO"""
    <DebtModalFrame id="debt-form-modal">
      <h2 id="debt-form-title" class="font-semibold text-lg mb-4">
        {%if @modal.type == :add_debt}Add debt{%else}Edit debt{/if}
      </h2>

      <form id="debt-form" class="flex flex-col gap-1" $submit="save">
        <label class="fieldset mb-2">
          <span class="label mb-1">Name</span>
          <input id="debt-name" type="text" class="w-full input" value={@form.name} $change={:set_field, field: :name} />
          {%for msg <- DebtLogic.field_errors(@errors, :name)}
            <p class="mt-1.5 text-sm text-error">{msg}</p>
          {/for}
        </label>

        <label class="fieldset mb-2">
          <span class="label mb-1">Type</span>
          <select id="debt-type" class="w-full select" value={@form.type} $change={:set_field, field: :type}>
            <option value="" selected={@form.type == ""}>Choose a type</option>
            <option value="revolving" selected={@form.type == "revolving"}>Revolving (credit card)</option>
            <option value="installment" selected={@form.type == "installment"}>Installment (loan, BNPL)</option>
          </select>
          {%for msg <- DebtLogic.field_errors(@errors, :type)}
            <p class="mt-1.5 text-sm text-error">{msg}</p>
          {/for}
        </label>

        <label class="fieldset mb-2">
          <span class="label mb-1">Current balance</span>
          <input id="debt-balance" type="text" inputmode="decimal" class="w-full input" value={@form.balance} $change={:set_field, field: :balance} />
          {%for msg <- DebtLogic.field_errors(@errors, :balance)}
            <p class="mt-1.5 text-sm text-error">{msg}</p>
          {/for}
        </label>

        <label class="fieldset mb-2">
          <span class="label mb-1">Original balance (optional)</span>
          <input id="debt-original-balance" type="text" inputmode="decimal" class="w-full input" value={@form.original_balance} $change={:set_field, field: :original_balance} />
          {%for msg <- DebtLogic.field_errors(@errors, :original_balance)}
            <p class="mt-1.5 text-sm text-error">{msg}</p>
          {/for}
        </label>

        <label class="fieldset mb-2">
          <span class="label mb-1">APR %</span>
          <input id="debt-apr" type="text" inputmode="decimal" class="w-full input" value={@form.apr} $change={:set_field, field: :apr} />
          {%for msg <- DebtLogic.field_errors(@errors, :apr)}
            <p class="mt-1.5 text-sm text-error">{msg}</p>
          {/for}
        </label>

        {%if @form.type == "revolving"}
          <div id="debt-revolving-fields">
            <label class="fieldset mb-2">
              <span class="label mb-1">Minimum payment floor</span>
              <input id="debt-minimum-payment-floor" type="text" inputmode="decimal" class="w-full input" value={@form.minimum_payment_floor} $change={:set_field, field: :minimum_payment_floor} />
              {%for msg <- DebtLogic.field_errors(@errors, :minimum_payment_floor)}
                <p class="mt-1.5 text-sm text-error">{msg}</p>
              {/for}
            </label>
            <label class="fieldset mb-2">
              <span class="label mb-1">Minimum payment rate (e.g. 0.02 for 2%)</span>
              <input id="debt-minimum-payment-rate" type="text" inputmode="decimal" class="w-full input" value={@form.minimum_payment_rate} $change={:set_field, field: :minimum_payment_rate} />
              {%for msg <- DebtLogic.field_errors(@errors, :minimum_payment_rate)}
                <p class="mt-1.5 text-sm text-error">{msg}</p>
              {/for}
            </label>
            <label class="fieldset mb-2">
              <span class="label mb-1">Credit limit (optional)</span>
              <input id="debt-credit-limit" type="text" inputmode="decimal" class="w-full input" value={@form.credit_limit} $change={:set_field, field: :credit_limit} />
              {%for msg <- DebtLogic.field_errors(@errors, :credit_limit)}
                <p class="mt-1.5 text-sm text-error">{msg}</p>
              {/for}
            </label>
          </div>
        {/if}

        {%if @form.type == "installment"}
          <div id="debt-installment-fields">
            <label class="fieldset mb-2">
              <span class="label mb-1">Fixed monthly payment</span>
              <input id="debt-fixed-payment" type="text" inputmode="decimal" class="w-full input" value={@form.fixed_payment} $change={:set_field, field: :fixed_payment} />
              {%for msg <- DebtLogic.field_errors(@errors, :fixed_payment)}
                <p class="mt-1.5 text-sm text-error">{msg}</p>
              {/for}
            </label>
            <label class="fieldset mb-2">
              <span class="label mb-1">Due-date tracking</span>
              <select id="debt-auto-log-mode" class="w-full select" value={@form.auto_log_mode} $change={:set_field, field: :auto_log_mode}>
                <option value="off" selected={@form.auto_log_mode == "off"}>Off</option>
                <option value="confirm" selected={@form.auto_log_mode == "confirm"}>Prompt me to confirm</option>
                <option value="automatic" selected={@form.auto_log_mode == "automatic"}>Post automatically</option>
              </select>
              {%for msg <- DebtLogic.field_errors(@errors, :auto_log_mode)}
                <p class="mt-1.5 text-sm text-error">{msg}</p>
              {/for}
            </label>
            {%if @form.auto_log_mode == "confirm" || @form.auto_log_mode == "automatic"}
              <label class="fieldset mb-2">
                <span class="label mb-1">Due day of month</span>
                <input id="debt-due-day" type="text" inputmode="numeric" class="w-full input" value={@form.due_day} $change={:set_field, field: :due_day} />
                {%for msg <- DebtLogic.field_errors(@errors, :due_day)}
                  <p class="mt-1.5 text-sm text-error">{msg}</p>
                {/for}
              </label>
            {/if}
          </div>
        {/if}

        <label class="fieldset mb-2">
          <span class="label">
            <input id="debt-exclude-from-plan" type="checkbox" class="checkbox checkbox-sm" checked={@form.exclude_from_plan} $change={:set_field, field: :exclude_from_plan} />
            Exclude from consumer payoff plan
          </span>
        </label>

        {%for msg <- DebtLogic.other_errors(@errors, [:name, :type, :balance, :original_balance, :apr, :minimum_payment_floor, :minimum_payment_rate, :credit_limit, :fixed_payment, :auto_log_mode, :due_day])}
          <p class="text-sm text-error">{msg}</p>
        {/for}

        <div class="flex flex-col sm:flex-row sm:justify-between gap-2 mt-2">
          {%if @modal.type == :edit_debt}
            <div>
              {%if @confirm_delete}
                <div id="debt-delete-confirm" class="flex flex-col gap-1 text-sm">
                  <span>Delete this debt? This can't be undone.</span>
                  <div class="flex gap-2">
                    <button id="confirm-delete-debt-button" type="button" class="btn btn-error" $click="delete">Yes, delete</button>
                    <button id="cancel-delete-debt-button" type="button" class="btn" $click="cancel_delete">Keep</button>
                  </div>
                </div>
              {%else}
                <button id="delete-debt-button" type="button" class="btn btn-error btn-outline" $click="ask_delete">Delete</button>
              {/if}
            </div>
          {/if}
          <div class="flex gap-2 sm:ml-auto">
            <button id="debt-form-cancel" type="button" class="btn" $click={action: :close_modal, target: "page"}>Cancel</button>
            <button id="debt-form-save" type="submit" class="btn btn-primary">Save</button>
          </div>
        </div>
      </form>
    </DebtModalFrame>
    """
  end

  def action(:set_field, %{field: field, event: %{value: value}}, component),
    do: put_state(component, :form, DebtLogic.put_field(component.state.form, field, value))

  def action(:save, _params, component) do
    modal = component.props.modal

    case DebtLogic.debt_change(component.state.form) do
      {:ok, attrs} ->
        change =
          if modal.type == :edit_debt,
            do: {:update_debt, modal.debt_id, attrs},
            else: {:add_debt, attrs}

        notice = "Saved #{attrs.name}."

        component
        |> put_state(:errors, %{})
        |> save([change], notice)

      {:error, errors} ->
        put_state(component, :errors, errors)
    end
  end

  def action(:ask_delete, _params, component), do: put_state(component, :confirm_delete, true)
  def action(:cancel_delete, _params, component), do: put_state(component, :confirm_delete, false)

  def action(:delete, _params, component) do
    modal = component.props.modal
    name = component.state.form.name

    component
    |> put_state(:confirm_delete, false)
    |> save([{:delete_debt, modal.debt_id}], "#{name} deleted.")
  end

  def action(:save_failed, %{error: error}, component),
    do: put_state(component, :errors, DebtLogic.error_map(error))

  # Plaintext: the `:save` command; E2EE: the page's ledger path. Either way
  # the reply is the sidebar's `:synced` (closing this modal) or `:save_failed`.
  defp save(component, changes, notice) do
    DataPath.save(component, :save, %{changes: changes, notice: notice},
      changes: changes,
      ok: DataPath.synced(notice, true),
      error: DataPath.error(:save_failed, "debt_form_modal")
    )
  end

  def command(:save, %{changes: changes, notice: notice}, server),
    do: DebtCommands.run(server, changes, notice, close_modal: true)
end
