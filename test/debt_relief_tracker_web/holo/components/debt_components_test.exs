defmodule DebtReliefTrackerWeb.Holo.Components.DebtComponentsTest do
  @moduledoc """
  The debt components' actions and commands are plain functions, so these
  drive them directly (port of the matching DashboardLive tests: add/edit/
  delete, log payment, mark paid, log all balances, due prompts).
  """

  use DebtReliefTracker.DataCase

  alias DebtReliefTracker.{Accounts, Debts, Storage}
  alias DebtReliefTrackerWeb.Holo.Components.{
    DebtFormModal,
    DebtSidebar,
    LogAllBalancesModal,
    PaymentModal
  }

  alias DebtReliefTrackerWeb.Holo.DashboardPage
  alias Hologram.Component
  alias Hologram.Server

  setup do
    workspace = Accounts.ensure_default_workspace!()

    {:ok, card} =
      Debts.create_debt(workspace, nil, %{
        "name" => "Visa",
        "type" => "revolving",
        "balance" => "4500.00",
        "apr" => "0",
        "minimum_payment_floor" => "35.00",
        "minimum_payment_rate" => "0.02"
      })

    %{workspace: workspace, card: card, today: Date.to_iso8601(Date.utc_today())}
  end

  defp snapshot(workspace) do
    {:ok, snapshot} = Storage.load(workspace)
    snapshot
  end

  defp component(props, state), do: %Component{props: props, state: state}

  defp server, do: Server.put_stash(%Server{}, :holo_user_id, nil)

  # Runs the command a component action queued, then the action it replies with.
  defp run_command(%Component{next_command: command}, module) do
    %Server{next_action: action} = module.command(command.name, command.params, server())
    action
  end

  defp apply_sidebar_synced(action, sidebar) do
    assert action.name == :synced
    assert action.target == "debt_sidebar"
    DebtSidebar.action(:synced, action.params, sidebar)
  end

  describe "DebtSidebar" do
    test "init/3 supplies today from the server", %{today: today} do
      sidebar = DebtSidebar.init(%{}, %Component{}, server())
      assert sidebar.state.today == today
    end

    test "buttons open modals through the page, carrying the server's today", %{
      workspace: workspace,
      card: card,
      today: today
    } do
      sidebar = component(%{snapshot: snapshot(workspace)}, %{today: today})

      for {name, params, modal} <- [
            {:open_add_debt, %{}, %{type: :add_debt, today: today}},
            {:open_edit_debt, %{id: card.id}, %{type: :edit_debt, debt_id: card.id, today: today}},
            {:open_log_payment, %{id: card.id}, %{type: :log_payment, debt_id: card.id, today: today}},
            {:open_log_all_balances, %{}, %{type: :log_all_balances, today: today}},
            {:open_activity_log, %{}, %{type: :activity_log}}
          ] do
        result = DebtSidebar.action(name, params, sidebar)
        assert result.next_action.name == :open_modal
        assert result.next_action.target == "page"
        assert result.next_action.params == %{modal: modal}
      end
    end

    test "mark paid asks first, then marks the debt paid off", %{
      workspace: workspace,
      card: card,
      today: today
    } do
      sidebar = component(%{snapshot: snapshot(workspace)}, %{today: today, confirm_paid_id: nil})

      asked = DebtSidebar.action(:ask_mark_paid, %{id: card.id}, sidebar)
      assert asked.state.confirm_paid_id == card.id

      confirmed = DebtSidebar.action(:mark_paid, %{id: card.id}, asked)
      assert confirmed.state.confirm_paid_id == nil

      reply = run_command(confirmed, DebtSidebar)
      assert Debts.get_debt!(workspace, card.id).status == :paid_off

      synced = apply_sidebar_synced(reply, confirmed)
      assert synced.state.notice == "Visa marked as paid off."
      assert synced.next_action.name == :snapshot_updated
      assert synced.next_action.target == "page"
      assert synced.next_action.params.close_modal == false

      assert Enum.find(synced.next_action.params.snapshot.debts, &(&1.id == card.id)).status ==
               "paid_off"
    end

    test "a confirm-mode due payment prompts; Log it posts, Skip only stamps", %{
      workspace: workspace,
      today: today
    } do
      attrs = fn name ->
        %{
          "name" => name,
          "type" => "installment",
          "balance" => "1000.00",
          "apr" => "5.00",
          "fixed_payment" => "150.00",
          "auto_log_mode" => "confirm",
          "due_day" => to_string(Date.utc_today().day)
        }
      end

      {:ok, post} = Debts.create_debt(workspace, nil, attrs.("Post Loan"))
      {:ok, skip} = Debts.create_debt(workspace, nil, attrs.("Skip Loan"))

      sidebar = component(%{snapshot: snapshot(workspace)}, %{today: today})

      prompts = DebtReliefTrackerWeb.Holo.DebtLogic.due_prompts(sidebar.props.snapshot, today)
      assert Enum.map(prompts, & &1.name) |> Enum.sort() == ["Post Loan", "Skip Loan"]
      assert Enum.all?(prompts, &(&1.cycle == today))

      logged = DebtSidebar.action(:due_decision, %{id: post.id, decision: :post, cycle: today}, sidebar)
      synced = logged |> run_command(DebtSidebar) |> apply_sidebar_synced(logged)
      assert synced.state.notice == "Logged Post Loan's payment."

      reloaded = Debts.get_debt!(workspace, post.id)
      assert Decimal.equal?(reloaded.balance, Decimal.new("850.00"))
      assert reloaded.last_due_handled_on == Date.utc_today()

      skipped = DebtSidebar.action(:due_decision, %{id: skip.id, decision: :skip, cycle: today}, sidebar)
      synced = skipped |> run_command(DebtSidebar) |> apply_sidebar_synced(skipped)
      assert synced.state.notice == "Skipped Skip Loan this month."

      reloaded = Debts.get_debt!(workspace, skip.id)
      assert Decimal.equal?(reloaded.balance, Decimal.new("1000.00"))
      assert reloaded.last_due_handled_on == Date.utc_today()

      # Both cycles handled -> no prompts left in the fresh snapshot.
      assert DebtReliefTrackerWeb.Holo.DebtLogic.due_prompts(
               synced.next_action.params.snapshot,
               today
             ) == []
    end

    test "a failed change shows an error and keeps the page untouched", %{today: today} do
      sidebar = component(%{}, %{today: today, notice: "old", error: nil})
      failed = DebtSidebar.action(:failed, %{error: :not_due}, sidebar)
      assert failed.state.notice == nil
      assert failed.state.error =~ "isn't due"
      assert failed.next_action == nil
    end
  end

  describe "DebtFormModal" do
    test "add: required type-specific fields are enforced and nothing is sent", %{
      workspace: workspace
    } do
      props = %{snapshot: snapshot(workspace), modal: %{type: :add_debt, today: "2026-10-31"}}
      modal = DebtFormModal.init(props, %Component{props: props})

      modal =
        Enum.reduce(
          [name: "Bad Loan", type: "installment", balance: "500", apr: "5"],
          modal,
          fn {field, value}, acc ->
            DebtFormModal.action(:set_field, %{field: field, event: %{value: value}}, acc)
          end
        )

      result = DebtFormModal.action(:save, %{}, modal)
      assert result.state.errors == %{fixed_payment: ["can't be blank"]}
      assert result.next_command == nil
    end

    test "add: saving sends an :add_debt change and the reply closes the modal", %{
      workspace: workspace
    } do
      props = %{snapshot: snapshot(workspace), modal: %{type: :add_debt, today: "2026-10-31"}}
      modal = DebtFormModal.init(props, %Component{props: props})

      modal =
        Enum.reduce(
          [
            name: "Auto Loan",
            type: "installment",
            balance: "1000",
            apr: "5",
            fixed_payment: "150",
            auto_log_mode: "confirm",
            due_day: "15"
          ],
          modal,
          fn {field, value}, acc ->
            DebtFormModal.action(:set_field, %{field: field, event: %{value: value}}, acc)
          end
        )

      saved = DebtFormModal.action(:save, %{}, modal)
      assert %{params: %{changes: [{:add_debt, attrs}], notice: "Saved Auto Loan."}} = saved.next_command
      assert attrs.fixed_payment == 15_000

      reply = run_command(saved, DebtFormModal)
      assert reply.target == "debt_sidebar"
      assert reply.params.close_modal == true

      debt = Enum.find(Debts.list_debts(workspace), &(&1.name == "Auto Loan"))
      assert Decimal.equal?(debt.fixed_payment, Decimal.new("150.00"))
      assert debt.due_day == 15

      # The sidebar relays the new snapshot and asks the page to close the modal.
      sidebar = component(%{}, %{today: "2026-10-31"})
      synced = DebtSidebar.action(:synced, reply.params, sidebar)
      assert synced.next_action.params.close_modal == true

      page = DashboardPage.action(:snapshot_updated, synced.next_action.params, component(%{}, %{modal: %{type: :add_debt}}))
      assert page.state.modal == nil
      assert Enum.any?(page.state.snapshot.debts, &(&1.name == "Auto Loan"))
    end

    test "edit: pre-fills from the snapshot and updates; server errors show on the form", %{
      workspace: workspace,
      card: card
    } do
      props = %{
        snapshot: snapshot(workspace),
        modal: %{type: :edit_debt, debt_id: card.id, today: "2026-10-31"}
      }

      modal = DebtFormModal.init(props, %Component{props: props})
      assert modal.state.form.name == "Visa"
      assert modal.state.form.balance == "4500.00"
      assert modal.state.form.minimum_payment_rate == "0.02"

      modal = DebtFormModal.action(:set_field, %{field: :balance, event: %{value: "4000"}}, modal)
      saved = DebtFormModal.action(:save, %{}, modal)
      assert %{params: %{changes: [{:update_debt, id, %{balance: 400_000}}]}} = saved.next_command
      assert id == card.id

      run_command(saved, DebtFormModal)
      assert Decimal.equal?(Debts.get_debt!(workspace, card.id).balance, Decimal.new("4000.00"))

      failed = DebtFormModal.action(:save_failed, %{error: {:invalid, %{name: ["can't be blank"]}}}, modal)
      assert failed.state.errors == %{name: ["can't be blank"]}
    end

    test "delete is only offered on edit, asks first, then removes the debt", %{
      workspace: workspace,
      card: card
    } do
      props = %{
        snapshot: snapshot(workspace),
        modal: %{type: :edit_debt, debt_id: card.id, today: "2026-10-31"}
      }

      modal = DebtFormModal.init(props, %Component{props: props})
      asked = DebtFormModal.action(:ask_delete, %{}, modal)
      assert asked.state.confirm_delete

      deleting = DebtFormModal.action(:delete, %{}, asked)
      assert %{params: %{changes: [{:delete_debt, id}], notice: "Visa deleted."}} = deleting.next_command
      assert id == card.id
      refute deleting.state.confirm_delete

      reply = run_command(deleting, DebtFormModal)
      assert reply.params.close_modal
      assert Debts.list_debts(workspace) == []
    end
  end

  describe "PaymentModal" do
    test "defaults paid-on to today; logging a payment reduces the balance", %{
      workspace: workspace,
      card: card,
      today: today
    } do
      props = %{snapshot: snapshot(workspace), modal: %{type: :log_payment, debt_id: card.id, today: today}}
      modal = PaymentModal.init(props, %Component{props: props})
      assert modal.state.form.paid_on == today
      assert modal.state.debt_name == "Visa"

      invalid = PaymentModal.action(:save, %{}, modal)
      assert invalid.state.errors == %{amount: ["can't be blank"]}
      assert invalid.next_command == nil

      modal = PaymentModal.action(:set_field, %{field: :amount, event: %{value: "500"}}, modal)
      saved = PaymentModal.action(:save, %{}, modal)
      assert saved.next_command.params.notice == "Logged payment on Visa."

      reply = run_command(saved, PaymentModal)
      assert reply.params.close_modal
      assert Decimal.equal?(Debts.get_debt!(workspace, card.id).balance, Decimal.new("4000.00"))
    end

    test "a payment larger than the balance is rejected by the server and shown", %{
      workspace: workspace,
      card: card,
      today: today
    } do
      props = %{snapshot: snapshot(workspace), modal: %{type: :log_payment, debt_id: card.id, today: today}}
      modal = PaymentModal.init(props, %Component{props: props})
      modal = PaymentModal.action(:set_field, %{field: :amount, event: %{value: "9000"}}, modal)
      saved = PaymentModal.action(:save, %{}, modal)

      reply = run_command(saved, PaymentModal)
      assert reply.name == :save_failed

      failed = PaymentModal.action(:save_failed, reply.params, saved)
      assert failed.state.errors != %{}
      assert Decimal.equal?(Debts.get_debt!(workspace, card.id).balance, Decimal.new("4500.00"))
    end
  end

  describe "LogAllBalancesModal" do
    test "pre-fills estimated balances; saving reconciles each entered debt", %{
      workspace: workspace,
      card: card,
      today: today
    } do
      props = %{snapshot: snapshot(workspace), modal: %{type: :log_all_balances, today: today}}
      modal = LogAllBalancesModal.init(props, %Component{props: props})
      assert [%{id: id, name: "Visa", value: "4500.00"}] = modal.state.entries
      assert id == card.id

      modal = LogAllBalancesModal.action(:set_balance, %{id: card.id, event: %{value: "4000.00"}}, modal)
      saved = LogAllBalancesModal.action(:save, %{}, modal)
      assert saved.next_command.params.changes == [{:reconcile_balance, card.id, 400_000}]

      reply = run_command(saved, LogAllBalancesModal)
      assert reply.params.notice == "Balances updated."
      assert reply.params.close_modal
      assert Decimal.equal?(Debts.get_debt!(workspace, card.id).balance, Decimal.new("4000.00"))
    end

    test "an unparsable entry is flagged and nothing is sent", %{workspace: workspace, card: card, today: today} do
      props = %{snapshot: snapshot(workspace), modal: %{type: :log_all_balances, today: today}}
      modal = LogAllBalancesModal.init(props, %Component{props: props})
      modal = LogAllBalancesModal.action(:set_balance, %{id: card.id, event: %{value: "abc"}}, modal)

      result = LogAllBalancesModal.action(:save, %{}, modal)
      assert result.next_command == nil
      assert [%{error: "is invalid"}] = result.state.entries
    end
  end
end
