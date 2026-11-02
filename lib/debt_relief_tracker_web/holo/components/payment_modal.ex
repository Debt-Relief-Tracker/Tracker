defmodule DebtReliefTrackerWeb.Holo.Components.PaymentModal do
  @moduledoc """
  Log-payment modal (modal type `:log_payment`, `modal.debt_id`, `modal.today`).
  Port of `DashboardLive`'s `payment_form_modal`, `validate_payment` and
  `save_payment`; the paid-on date defaults to the server-supplied today.
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
    today = (props.modal && Map.get(props.modal, :today)) || ""
    debt = props.modal && DebtLogic.find_debt(props.snapshot, Map.get(props.modal, :debt_id))

    component
    |> put_state(:form, DebtLogic.payment_form(today))
    |> put_state(:errors, %{})
    |> put_state(:debt_name, (debt && debt.name) || "")
  end

  def template do
    ~HOLO"""
    <DebtModalFrame id="payment-modal">
      <h2 id="payment-modal-title" class="font-semibold text-lg mb-4">Log payment -- {@debt_name}</h2>
      <form id="payment-form" class="flex flex-col gap-1" $submit="save">
        <label class="fieldset mb-2">
          <span class="label mb-1">Amount paid</span>
          <input id="payment-amount" type="text" inputmode="decimal" class="w-full input" value={@form.amount} $change={:set_field, field: :amount} />
          {%for msg <- DebtLogic.field_errors(@errors, :amount)}
            <p class="mt-1.5 text-sm text-error">{msg}</p>
          {/for}
        </label>
        <label class="fieldset mb-2">
          <span class="label mb-1">Principal portion (optional)</span>
          <input id="payment-principal" type="text" inputmode="decimal" class="w-full input" value={@form.principal_portion} $change={:set_field, field: :principal_portion} />
          {%for msg <- DebtLogic.field_errors(@errors, :principal_portion)}
            <p class="mt-1.5 text-sm text-error">{msg}</p>
          {/for}
        </label>
        <label class="fieldset mb-2">
          <span class="label mb-1">Interest portion (optional)</span>
          <input id="payment-interest" type="text" inputmode="decimal" class="w-full input" value={@form.interest_portion} $change={:set_field, field: :interest_portion} />
          {%for msg <- DebtLogic.field_errors(@errors, :interest_portion)}
            <p class="mt-1.5 text-sm text-error">{msg}</p>
          {/for}
        </label>
        <label class="fieldset mb-2">
          <span class="label mb-1">Paid on</span>
          <input id="payment-paid-on" type="date" class="w-full input" value={@form.paid_on} $change={:set_field, field: :paid_on} />
          {%for msg <- DebtLogic.field_errors(@errors, :paid_on)}
            <p class="mt-1.5 text-sm text-error">{msg}</p>
          {/for}
        </label>
        <label class="fieldset mb-2">
          <span class="label mb-1">Note (optional)</span>
          <input id="payment-note" type="text" class="w-full input" value={@form.note} $change={:set_field, field: :note} />
        </label>

        {%for msg <- DebtLogic.other_errors(@errors, [:amount, :principal_portion, :interest_portion, :paid_on, :note])}
          <p class="text-sm text-error">{msg}</p>
        {/for}

        <div class="flex justify-end gap-2 mt-2">
          <button id="payment-cancel" type="button" class="btn" $click={action: :close_modal, target: "page"}>Cancel</button>
          <button id="payment-save" type="submit" class="btn btn-primary">Log payment</button>
        </div>
      </form>
    </DebtModalFrame>
    """
  end

  def action(:set_field, %{field: field, event: %{value: value}}, component),
    do: put_state(component, :form, DebtLogic.put_field(component.state.form, field, value))

  def action(:save, _params, component) do
    case DebtLogic.payment_attrs(component.state.form) do
      {:ok, attrs} ->
        change = {:log_payment, component.props.modal.debt_id, attrs}

        notice = "Logged payment on #{component.state.debt_name}."

        component
        |> put_state(:errors, %{})
        |> DataPath.save(:save, %{changes: [change], notice: notice},
          changes: [change],
          ok: DataPath.synced(notice, true),
          error: DataPath.error(:save_failed, "payment_modal")
        )

      {:error, errors} ->
        put_state(component, :errors, errors)
    end
  end

  def action(:save_failed, %{error: error}, component),
    do: put_state(component, :errors, DebtLogic.error_map(error))

  def command(:save, %{changes: changes, notice: notice}, server),
    do: DebtCommands.run(server, changes, notice, close_modal: true)
end
