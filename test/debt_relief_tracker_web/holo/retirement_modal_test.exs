defmodule DebtReliefTrackerWeb.Holo.RetirementModalTest do
  # Ports the behavior of the "retirement roadmap" onboarding tests in
  # test/debt_relief_tracker_web/live/dashboard_live_test.exs as unit tests of
  # the component's actions, commands and the banner's visibility rule.
  use DebtReliefTracker.DataCase

  alias DebtReliefTracker.{Accounts, Settings, Storage}
  alias DebtReliefTrackerWeb.Holo.Components.{RetirementBanner, RetirementModal}
  alias DebtReliefTrackerWeb.Holo.RetirementForm
  alias Hologram.Component
  alias Hologram.Server

  setup do
    owner = Accounts.get_or_create_user_from_oidc!(%{"sub" => "a", "email" => "a@example.com"})
    workspace = Accounts.current_workspace_for_user(owner)
    {:ok, snapshot} = Storage.load(workspace)

    %{
      owner: owner,
      workspace: workspace,
      snapshot: snapshot,
      server: Server.put_stash(%Server{}, :holo_user_id, owner.id)
    }
  end

  defp component(snapshot, state \\ %{}) do
    base = %Component{
      props: %{snapshot: snapshot, account: %{}, modal: %{type: :retirement_onboarding}}
    }

    base |> then(&RetirementModal.init(&1.props, &1)) |> merge_state(state)
  end

  defp merge_state(component, state), do: %{component | state: Map.merge(component.state, state)}

  defp valid_form(overrides) do
    Map.merge(
      %{
        RetirementForm.blank()
        | current_age: "30",
          retirement_age: "65",
          current_retirement_savings: "1000",
          monthly_retirement_contribution: "100",
          monthly_gross_income: "4000",
          post_debt_investment_bp: "15",
          expected_annual_return_bp: "7"
      },
      overrides
    )
  end

  # Runs a component command's single follow-up action back through the
  # component, as the framework would, and returns the resulting component.
  defp follow(component, %Server{next_action: action}) do
    RetirementModal.action(action.name, action.params, component)
  end

  describe "banner" do
    test "shows for a fresh workspace, hides once a profile exists or it is dismissed", ctx do
      assert RetirementBanner.show?(ctx.snapshot)

      {:ok, with_profile} =
        Storage.apply_change(
          ctx.workspace,
          ctx.owner,
          {:add_member_retirement_profile, ctx.owner.id,
           %{
             current_age: 30,
             retirement_age: 65,
             current_retirement_savings: 0,
             monthly_retirement_contribution: 0,
             monthly_gross_income: 0,
             post_debt_investment_bp: 1500,
             expected_annual_return_bp: 700
           }}
        )

      refute RetirementBanner.show?(with_profile)
    end

    test "dismissing persists the flag and hands the snapshot to the page", ctx do
      server = RetirementBanner.command(:dismiss, %{}, ctx.server)

      assert %{name: :snapshot_updated, target: "page", params: %{snapshot: snapshot}} =
               server.next_action

      refute RetirementBanner.show?(snapshot)

      # ...and it stays dismissed on a later load.
      {:ok, reloaded} = Storage.load(ctx.workspace)
      refute RetirementBanner.show?(reloaded)
    end

    test "the dismiss action asks the server to dismiss", ctx do
      component =
        RetirementBanner.action(:dismiss, %{}, %Component{props: %{snapshot: ctx.snapshot}})

      assert component.next_command.name == :dismiss
    end
  end

  describe "adding a person" do
    test "opening the add form loads members; only unprofiled members are offered", ctx do
      component = component(ctx.snapshot)
      assert component.state.screen == :roster

      assert RetirementModal.action(:open_add_profile, %{}, component).next_command.name ==
               :load_members

      server = RetirementModal.command(:load_members, %{}, ctx.server)
      assert server.next_action.name == :members_loaded
      assert [%{id: id, display_name: _}] = server.next_action.params.members
      assert id == ctx.owner.id

      form_screen = follow(component, server)
      assert form_screen.state.screen == :form
      assert form_screen.state.source == "member"
      assert form_screen.state.form.user_id == ctx.owner.id
      assert form_screen.state.editing_profile_id == nil
    end

    test "with the only member already profiled, the form goes straight to manual", ctx do
      {:ok, snapshot} = add_owner_profile(ctx)
      component = component(snapshot)
      server = RetirementModal.command(:load_members, %{}, ctx.server)

      form_screen = follow(component, server)
      assert form_screen.state.members == []
      assert form_screen.state.source == "manual"
    end

    test "submitting a member profile saves it and returns to the roster", ctx do
      component = component(ctx.snapshot) |> open_form(ctx)

      component = merge_state(component, %{form: valid_form(%{user_id: ctx.owner.id})})
      submitted = RetirementModal.action(:submit, %{}, component)
      assert %{name: :save, params: %{change: change}} = submitted.next_command
      assert {:add_member_retirement_profile, _, %{retirement_age: 65}} = change

      server = RetirementModal.command(:save, %{change: change}, ctx.server)
      assert %{name: :saved, params: %{snapshot: snapshot}} = server.next_action
      assert [%{retirement_age: 65}] = snapshot.retirement_profiles

      saved = follow(submitted, server)
      assert saved.state.screen == :roster
      assert saved.state.errors == %{}
      assert %{name: :snapshot_updated, target: "page"} = saved.next_action

      assert [profile] = Settings.list_retirement_profiles(ctx.workspace)
      assert profile.retirement_age == 65
      assert profile.user_id == ctx.owner.id
    end

    test "can add a second person with no account of their own", ctx do
      {:ok, snapshot} = add_owner_profile(ctx)
      component = component(snapshot) |> open_form(ctx)
      assert component.state.source == "manual"

      form = valid_form(%{name: "Spouse", claim_email: "spouse@example.com"})
      component = merge_state(component, %{form: form})
      submitted = RetirementModal.action(:submit, %{}, component)
      server = RetirementModal.command(:save, submitted.next_command.params, ctx.server)

      assert server.next_action.name == :saved
      profiles = Settings.list_retirement_profiles(ctx.workspace)
      assert length(profiles) == 2
      assert Enum.any?(profiles, &(&1.name == "Spouse" and &1.user_id == nil))
    end

    test "rejects a retirement age that isn't after the current age, saving nothing", ctx do
      component =
        component(ctx.snapshot)
        |> open_form(ctx)
        |> merge_state(%{
          form: valid_form(%{user_id: ctx.owner.id, current_age: "40", retirement_age: "40"})
        })

      rejected = RetirementModal.action(:submit, %{}, component)
      assert rejected.next_command == nil
      assert rejected.state.errors == %{retirement_age: ["must be greater than current age"]}
      assert rejected.state.screen == :form
      assert Settings.list_retirement_profiles(ctx.workspace) == []
    end

    test "a server-side validation error is shown on the form", ctx do
      server =
        RetirementModal.command(
          :save,
          %{change: {:add_manual_retirement_profile, %{name: "X", current_age: nil}}},
          ctx.server
        )

      assert server.next_action.name == :save_failed
      failed = follow(component(ctx.snapshot), server)
      assert failed.state.errors[:current_age] == ["can't be blank"]
    end

    test "editing a field clears that field's error", ctx do
      component =
        merge_state(component(ctx.snapshot), %{errors: %{name: ["x"], current_age: ["y"]}})

      updated =
        RetirementModal.action(:set_field, %{field: :name, event: %{value: "Z"}}, component)

      assert updated.state.form.name == "Z"
      assert updated.state.errors == %{current_age: ["y"]}
    end

    test "canceling the form returns to the roster without saving anything", ctx do
      component = component(ctx.snapshot) |> open_form(ctx)
      assert component.state.screen == :form

      canceled = RetirementModal.action(:cancel_form, %{}, component)
      assert canceled.state.screen == :roster
      assert canceled.next_command == nil
      assert Settings.list_retirement_profiles(ctx.workspace) == []
    end
  end

  describe "editing and deleting" do
    test "edit pre-fills the form; update saves through the same command", ctx do
      {:ok, snapshot} = add_owner_profile(ctx)
      [profile] = snapshot.retirement_profiles

      edit = RetirementModal.action(:edit_profile, %{id: profile.id}, component(snapshot))
      assert edit.state.screen == :form
      assert edit.state.editing_profile_id == profile.id
      assert edit.state.editing_manual == false
      assert edit.state.form.retirement_age == "65"

      changed = merge_state(edit, %{form: %{edit.state.form | retirement_age: "62"}})
      submitted = RetirementModal.action(:submit, %{}, changed)

      assert {:update_retirement_profile, id, %{retirement_age: 62}} =
               submitted.next_command.params.change

      assert id == profile.id

      server = RetirementModal.command(:save, submitted.next_command.params, ctx.server)
      assert %{retirement_age: 62} = hd(server.next_action.params.snapshot.retirement_profiles)
    end

    test "delete removes the profile and delivers the snapshot", ctx do
      {:ok, snapshot} = add_owner_profile(ctx)
      [profile] = snapshot.retirement_profiles

      assert RetirementModal.action(:delete_profile, %{id: profile.id}, component(snapshot)).next_command ==
               %Component.Command{name: :delete, params: %{id: profile.id}}

      server = RetirementModal.command(:delete, %{id: profile.id}, ctx.server)

      assert %{name: :snapshot_updated, params: %{snapshot: %{retirement_profiles: []}}} =
               server.next_action

      assert Settings.list_retirement_profiles(ctx.workspace) == []
    end
  end

  describe "skip for now" do
    test "closes the modal and dismisses the prompt for good", ctx do
      component = RetirementModal.action(:dismiss_prompt, %{}, component(ctx.snapshot))
      assert component.next_command.name == :dismiss
      assert %{name: :close_modal, target: "page"} = component.next_action

      server = RetirementModal.command(:dismiss, %{}, ctx.server)
      assert %{name: :snapshot_updated, params: %{snapshot: snapshot}} = server.next_action
      assert snapshot.settings.retirement_onboarding_dismissed
    end
  end

  test "escape closes the roster but only backs out of the form", ctx do
    roster = component(ctx.snapshot)

    assert %{name: :close_modal, target: "page"} =
             RetirementModal.action(:escape, %{}, roster).next_action

    form = open_form(roster, ctx)
    backed = RetirementModal.action(:escape, %{}, form)
    assert backed.state.screen == :roster
    assert backed.next_action == nil
  end

  test "set_source switches between the member picker and manual entry", ctx do
    form = open_form(component(ctx.snapshot), ctx)

    manual = RetirementModal.action(:set_source, %{source: "manual"}, form)
    assert manual.state.source == "manual"

    assert RetirementModal.action(:set_source, %{source: "member"}, manual).state.source ==
             "member"
  end

  defp open_form(component, ctx) do
    server = RetirementModal.command(:load_members, %{}, ctx.server)
    follow(component, server)
  end

  defp add_owner_profile(ctx) do
    Storage.apply_change(
      ctx.workspace,
      ctx.owner,
      {:add_member_retirement_profile, ctx.owner.id,
       %{
         current_age: 30,
         retirement_age: 65,
         current_retirement_savings: 0,
         monthly_retirement_contribution: 0,
         monthly_gross_income: 0,
         post_debt_investment_bp: 1500,
         expected_annual_return_bp: 700
       }}
    )
  end
end
