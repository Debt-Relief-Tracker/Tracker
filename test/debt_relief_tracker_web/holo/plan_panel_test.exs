defmodule DebtReliefTrackerWeb.Holo.PlanPanelTest do
  # PlanPanel's actions and command as plain functions (Hologram actions run
  # in the browser; their results are just structs), porting the behavior of
  # the plan-control tests in dashboard_live_test.exs. Chart *drawing* is a
  # JS interop no-op here -- what's checked is the action that would draw.
  use DebtReliefTracker.DataCase

  alias DebtReliefTracker.{Accounts, Debts, Settings, Storage}
  alias DebtReliefTrackerWeb.Holo.Components.PlanPanel
  alias Hologram.Component
  alias Hologram.Component.Action
  alias Hologram.Component.Command

  setup do
    workspace = Accounts.ensure_default_workspace!()

    {:ok, _} =
      Debts.create_debt(workspace, nil, %{
        "name" => "Visa",
        "type" => "revolving",
        "balance" => "4500.00",
        "apr" => "24.99",
        "minimum_payment_floor" => "35.00",
        "minimum_payment_rate" => "0.02"
      })

    {:ok, snapshot} = Storage.load(workspace)
    %{workspace: workspace, snapshot: snapshot}
  end

  defp mount(snapshot, strategy \\ :cash_flow) do
    props = %{snapshot: snapshot, account: %{}, strategy: strategy, cid: "plan_panel"}
    component = PlanPanel.init(props, %Component{props: props}, %Hologram.Server{})
    %{component | props: props, next_action: nil}
  end

  defp run(component, name, params \\ %{}),
    do: PlanPanel.action(name, params, %{component | next_action: nil, next_command: nil})

  defp server, do: Hologram.Server.put_stash(%Hologram.Server{}, :holo_user_id, nil)

  describe "init/3 (server render)" do
    test "derives the cards for the comparison chart and queues the first draw", %{snapshot: s} do
      props = %{snapshot: s, account: %{}, strategy: :cash_flow}
      component = PlanPanel.init(props, %Component{props: props}, %Hologram.Server{})

      assert component.state.chart_type == :comparison
      assert component.state.chart_message == nil
      assert [%{name: "Visa", extra: true}] = component.state.view.this_month.lines
      assert %Action{name: :plan_inputs_changed} = component.next_action
    end
  end

  describe "chart drawing" do
    test "plan_inputs_changed sends the config to the plan_chart component", %{snapshot: s} do
      component = s |> mount() |> run(:plan_inputs_changed)

      assert %Action{name: :draw, target: "plan_chart", params: %{config: %{type: "bar"}}} =
               component.next_action
    end

    test "switching chart type re-draws with the matching Chart.js type", %{snapshot: s} do
      expected = %{
        comparison: "bar",
        simulation: "line",
        monthly_payments: "line",
        freed_cashflow: "line"
      }

      for {chart_type, js_type} <- expected do
        component = s |> mount() |> run(:select_chart_type, %{chart_type: chart_type})
        assert component.state.chart_type == chart_type
        assert %Action{name: :draw, params: %{config: %{type: ^js_type}}} = component.next_action
      end
    end

    test "a chart with nothing to plot clears the canvas and shows the message", %{snapshot: s} do
      component = s |> mount() |> run(:select_chart_type, %{chart_type: :interest_breakdown})

      assert component.state.chart_message =~ "Log a payment"
      assert %Action{name: :clear, target: "plan_chart"} = component.next_action
    end

    test "ignores chart types it doesn't know", %{snapshot: s} do
      component = mount(s)
      assert run(component, :select_chart_type, %{chart_type: :pie}).state == component.state
    end

    test "the retirement roadmap shows its setup message", %{snapshot: s} do
      component = s |> mount() |> run(:select_chart_type, %{chart_type: :retirement_roadmap})
      assert component.state.chart_message =~ "retirement profile"
    end

    test "the mobile selects map option strings back to atoms", %{snapshot: s} do
      component = mount(s)

      assert %Action{name: :select_chart_type, params: %{chart_type: :freed_cashflow}} =
               run(component, :chart_type_selected, %{event: %{value: "freed_cashflow"}}).next_action

      assert run(component, :chart_type_selected, %{event: %{value: "nope"}}).next_action == nil

      assert %Action{name: :select_strategy, target: "page", params: %{strategy: :avalanche}} =
               run(component, :strategy_selected, %{event: %{value: "avalanche"}}).next_action
    end

    test "a new strategy (via the page) re-plans from the current props", %{snapshot: s} do
      component = mount(s)
      component = %{component | props: %{component.props | strategy: :avalanche}}
      component = run(component, :plan_inputs_changed)
      assert component.state.view.this_month.lines != []
    end
  end

  describe "budget" do
    test "typing re-plans locally without saving", %{snapshot: s} do
      component = mount(s)
      [%{payment: before}] = component.state.view.this_month.lines

      component = run(component, :budget_changed, %{event: %{value: "1000"}})

      assert component.state.budget_draft == "1000"
      assert [%{payment: 100_000}] = component.state.view.this_month.lines
      assert before != 100_000
      assert component.next_command == nil
    end

    test "the debounced save sends the total in cents", %{snapshot: s} do
      component = s |> mount() |> run(:budget_changed, %{event: %{value: "1000"}})

      assert %Command{name: :save_settings, params: %{attrs: %{monthly_budget: 100_000}}} =
               run(component, :save_budget).next_command
    end

    test "in margin mode the save stores minimums + margin", %{snapshot: s} do
      s = put_in(s.settings.budget_mode, "margin")
      component = s |> mount() |> run(:budget_changed, %{event: %{value: "50"}})

      # Visa: 2% of $4,500 = $90 minimum.
      assert %Command{params: %{attrs: %{monthly_budget: 14_000}}} =
               run(component, :save_budget).next_command
    end

    test "nothing is saved for unparseable or unchanged input", %{snapshot: s} do
      component = s |> mount() |> run(:budget_changed, %{event: %{value: "12abc"}})
      assert run(component, :save_budget).next_command == nil

      s = put_in(s.settings.monthly_budget, 100_000)
      component = s |> mount() |> run(:budget_changed, %{event: %{value: "1000.00"}})
      assert run(component, :save_budget).next_command == nil
    end

    test "on blur an invalid draft reverts; an unsaved one stays until saved", %{snapshot: s} do
      component =
        s
        |> mount()
        |> run(:budget_focused)
        |> run(:budget_changed, %{event: %{value: "abc"}})
        |> run(:budget_blurred)

      assert component.state.budget_draft == nil

      component =
        s
        |> mount()
        |> run(:budget_focused)
        |> run(:budget_changed, %{event: %{value: "1000"}})
        |> run(:budget_blurred)

      assert component.state.budget_draft == "1000"

      saved = %{component | props: %{component.props | snapshot: put_in(s.settings.monthly_budget, 100_000)}}
      assert run(saved, :plan_inputs_changed).state.budget_draft == nil
    end

    test "switching budget mode is immediate and persisted", %{snapshot: s} do
      component = s |> mount() |> run(:select_budget_mode, %{mode: :margin})

      assert component.state.mode_pending == :margin
      assert PlanPanel.mode(component.state.mode_pending, s) == :margin

      assert %Command{name: :save_settings, params: %{attrs: %{budget_mode: "margin"}}} =
               component.next_command
    end

    test "a successful save hands the fresh snapshot to the page", %{snapshot: s} do
      component = s |> mount() |> run(:select_budget_mode, %{mode: :margin})
      component = run(component, :settings_saved, %{snapshot: s})

      assert component.state.mode_pending == nil

      assert %Action{name: :snapshot_updated, target: "page", params: %{snapshot: ^s}} =
               component.next_action
    end

    test "a failed save shows an error and falls back to the saved mode", %{snapshot: s} do
      component =
        s |> mount() |> run(:select_budget_mode, %{mode: :margin}) |> run(:save_failed)

      assert component.state.save_error =~ "Couldn't save"
      assert component.state.mode_pending == nil
    end
  end

  describe "command :save_settings" do
    test "persists the budget and returns the fresh snapshot", %{workspace: workspace} do
      server = PlanPanel.command(:save_settings, %{attrs: %{monthly_budget: 123_456}}, server())

      assert %Action{name: :settings_saved, params: %{snapshot: snapshot}} = server.next_action
      assert snapshot.settings.monthly_budget == 123_456
      assert Decimal.equal?(Settings.get_settings!(workspace).monthly_budget, Decimal.new("1234.56"))
    end

    test "persists the budget mode", %{workspace: workspace} do
      PlanPanel.command(:save_settings, %{attrs: %{budget_mode: "margin"}}, server())
      assert Settings.get_settings!(workspace).budget_mode == :margin
    end

    test "only touches the settings this panel owns", %{workspace: workspace} do
      PlanPanel.command(
        :save_settings,
        %{attrs: %{currency: "EUR", budget_mode: "bogus", monthly_budget: "1"}},
        server()
      )

      settings = Settings.get_settings!(workspace)
      assert settings.currency == "USD"
      assert settings.budget_mode != :bogus
      assert settings.monthly_budget == nil
    end
  end
end
