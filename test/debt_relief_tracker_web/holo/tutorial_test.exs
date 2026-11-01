defmodule DebtReliefTrackerWeb.Holo.TutorialTest do
  use DebtReliefTracker.DataCase

  alias DebtReliefTracker.Accounts
  alias DebtReliefTrackerWeb.Holo.Components.Footer
  alias DebtReliefTrackerWeb.Holo.Components.TutorialOverlay
  alias DebtReliefTrackerWeb.Holo.DashboardPage
  alias DebtReliefTrackerWeb.Holo.Tutorial
  alias Hologram.Component
  alias Hologram.Server

  defp overlay(state \\ %{step: nil, view: nil}), do: %Component{state: state}

  defp actions(%Component{next_action: nil}), do: []
  defp actions(%Component{next_action: a}), do: [a]

  describe "Holo.Tutorial" do
    test "has the seven original steps; the first is a targetless welcome" do
      assert Tutorial.count() == 7
      assert Tutorial.step(0).target == nil
      assert Tutorial.step(1).target == "#add-debt-button"
      assert Tutorial.step(6).target == "#settings-button"
    end

    test "steps 5 and 6 switch the chart type so the strategy switcher exists" do
      assert Tutorial.step(4).chart_type == :comparison
      assert Tutorial.step(5).chart_type == :simulation
    end

    test "next walks through every step then finishes; prev stops at the first" do
      assert Tutorial.next(0) == {:step, 1}
      assert Tutorial.next(5) == {:step, 6}
      assert Tutorial.next(6) == :finish
      assert Tutorial.prev(0) == {:step, 0}
      assert Tutorial.prev(3) == {:step, 2}
    end

    test "view/1 gives progress and button labels" do
      assert %{progress: "Step 1 of 7", first?: true, next_label: "Next"} = Tutorial.view(0)
      assert %{progress: "Step 7 of 7", first?: false, next_label: "Finish"} = Tutorial.view(6)
    end
  end

  describe "TutorialOverlay actions" do
    test "init queues :auto_start only when the tutorial is unseen" do
      props = fn seen -> %{account: %{user: %{tutorial_seen: seen}}} end

      unseen = TutorialOverlay.init(props.(false), %Component{}, %Server{})
      assert Enum.any?(actions(unseen), &(&1.name == :auto_start))

      seen = TutorialOverlay.init(props.(true), %Component{}, %Server{})
      assert actions(seen) == []
      assert seen.state.view == nil
    end

    test ":auto_start shows the centered welcome step and queues no follow-up action" do
      c = TutorialOverlay.action(:auto_start, %{}, overlay())
      assert c.state.step == 0
      assert c.state.view.title == "Welcome to your debt tracker"
      assert actions(c) == []
      assert c.state.card_style == Tutorial.centered_card_style()
    end

    test ":next on the chart steps asks plan_panel to switch chart type" do
      c = TutorialOverlay.action(:next, %{}, overlay(%{step: 3, view: %{}}))
      assert c.state.step == 4
      action = Enum.find(actions(c), &(&1.name == :select_chart_type))
      assert action.target == "plan_panel"
      assert action.params == %{chart_type: :comparison}

      c = TutorialOverlay.action(:next, %{}, overlay(%{step: 4, view: %{}}))
      action = Enum.find(actions(c), &(&1.name == :select_chart_type))
      assert action.params == %{chart_type: :simulation}
    end

    test ":prev goes back and never below the first step" do
      c = TutorialOverlay.action(:prev, %{}, overlay(%{step: 2, view: %{}}))
      assert c.state.step == 1
      c = TutorialOverlay.action(:prev, %{}, overlay(%{step: 0, view: %{}}))
      assert c.state.step == 0
    end

    test ":next past the last step and :skip hide the overlay and persist seen" do
      for {name, step} <- [next: 6, skip: 2] do
        c = TutorialOverlay.action(name, %{}, overlay(%{step: step, view: %{}}))
        assert c.state.view == nil
        assert c.state.step == nil
        assert c.next_command.name == :set_seen
        assert c.next_command.params == %{seen: true}
      end
    end

    test ":restart persists seen=false, resets to the comparison chart and step 1" do
      c = TutorialOverlay.action(:restart, %{}, overlay())
      assert c.state.step == 0
      assert c.next_command.params == %{seen: false}
      assert c.state.view.title == "Welcome to your debt tracker"
      assert [%{name: :select_chart_type, target: "plan_panel", params: %{chart_type: :comparison}}] =
               actions(c)
    end

    test "the page's :restart_tutorial closes the modal and targets the overlay" do
      page = %Component{state: %{modal: %{type: :settings}}}
      c = DashboardPage.action(:restart_tutorial, %{}, page)
      assert c.state.modal == nil
      assert Enum.any?(actions(c), &(&1.name == :restart and &1.target == "tutorial_overlay"))
    end
  end

  describe "TutorialOverlay :set_seen command (no-auth mode)" do
    test "marks the default user seen, then unseen again" do
      Accounts.ensure_default_workspace!()
      server = Hologram.Server.put_stash(%Server{}, :holo_user_id, nil)
      refute Accounts.get_default_user!().tutorial_seen

      TutorialOverlay.command(:set_seen, %{seen: true}, server)
      assert Accounts.get_default_user!().tutorial_seen

      result = TutorialOverlay.command(:set_seen, %{seen: false}, server)
      refute Accounts.get_default_user!().tutorial_seen
      assert result.next_action.name == :seen_saved
    end
  end

  describe "Footer" do
    test "donate modal is hidden until opened" do
      assert Footer.donate_modal_class(false) =~ "hidden"
      refute Footer.donate_modal_class(true) =~ "hidden"

      c = Footer.action(:open_donate, %{}, %Component{state: %{donate_open: false}})
      assert c.state.donate_open
      c = Footer.action(:close_donate, %{}, c)
      refute c.state.donate_open
    end
  end
end
