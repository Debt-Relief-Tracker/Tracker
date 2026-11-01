defmodule DebtReliefTracker.Storage.RetirementProfilesTest do
  use DebtReliefTracker.DataCase

  alias DebtReliefTracker.{Accounts, Settings, Storage}
  alias DebtReliefTracker.Storage.Plain

  setup do
    owner = Accounts.get_or_create_user_from_oidc!(%{"sub" => "a", "email" => "a@example.com"})
    %{owner: owner, workspace: Accounts.current_workspace_for_user(owner)}
  end

  @attrs %{
    current_age: 30,
    retirement_age: 65,
    current_retirement_savings: 1_000_050,
    monthly_retirement_contribution: 10_000,
    monthly_gross_income: 500_000,
    post_debt_investment_bp: 1500,
    expected_annual_return_bp: 750
  }

  test "a fresh snapshot has no retirement profiles", %{workspace: workspace} do
    assert {:ok, %{retirement_profiles: []}} = Storage.load(workspace)
  end

  test "adds a member profile and snapshots it in cents and basis points", %{
    workspace: workspace,
    owner: owner
  } do
    assert {:ok, %{retirement_profiles: [profile]} = snapshot} =
             Plain.apply_change(
               workspace,
               owner,
               {:add_member_retirement_profile, owner.id, @attrs}
             )

    assert {:ok, _json} = Jason.encode(snapshot)

    assert %{
             user_id: user_id,
             name: nil,
             claim_email: nil,
             current_age: 30,
             retirement_age: 65,
             current_retirement_savings: 1_000_050,
             monthly_retirement_contribution: 10_000,
             monthly_gross_income: 500_000,
             post_debt_investment_bp: 1500,
             expected_annual_return_bp: 750
           } = profile

    assert user_id == owner.id
    assert profile.display_name == owner.display_name

    # Stored as Decimal dollars / percents underneath.
    assert [stored] = Settings.list_retirement_profiles(workspace)
    assert Decimal.equal?(stored.current_retirement_savings, Decimal.new("10000.50"))
    assert Decimal.equal?(stored.expected_annual_return_pct, Decimal.new("7.5"))
  end

  test "a member profile for someone who is not a confirmed member is :not_found", %{
    workspace: workspace,
    owner: owner
  } do
    stranger =
      Accounts.get_or_create_user_from_oidc!(%{"sub" => "b", "email" => "b@example.com"})

    for user_id <- [stranger.id, Ecto.UUID.generate(), "not-a-uuid"] do
      assert {:error, :not_found} =
               Plain.apply_change(
                 workspace,
                 owner,
                 {:add_member_retirement_profile, user_id, @attrs}
               )
    end
  end

  test "adds a manual profile with a name and claim email", %{workspace: workspace, owner: owner} do
    attrs = Map.merge(@attrs, %{name: "Spouse", claim_email: "spouse@example.com"})

    assert {:ok, %{retirement_profiles: [profile]}} =
             Plain.apply_change(workspace, owner, {:add_manual_retirement_profile, attrs})

    assert %{
             user_id: nil,
             name: "Spouse",
             display_name: "Spouse",
             claim_email: "spouse@example.com"
           } = profile
  end

  test "validation errors come back as {:invalid, errors}", %{workspace: workspace, owner: owner} do
    attrs = Map.merge(@attrs, %{name: "Spouse", current_age: 40, retirement_age: 40})

    assert {:error, {:invalid, %{retirement_age: ["must be greater than current age"]}}} =
             Plain.apply_change(workspace, owner, {:add_manual_retirement_profile, attrs})

    assert {:error, {:invalid, %{name: ["can't be blank"]}}} =
             Plain.apply_change(workspace, owner, {:add_manual_retirement_profile, @attrs})

    assert {:error, {:invalid, %{current_age: ["can't be blank"]}}} =
             Plain.apply_change(
               workspace,
               owner,
               {:add_manual_retirement_profile, %{name: "X", current_age: nil}}
             )

    assert {:ok, %{retirement_profiles: []}} = Plain.load(workspace)
  end

  test "a second profile for the same member is rejected", %{workspace: workspace, owner: owner} do
    change = {:add_member_retirement_profile, owner.id, @attrs}
    assert {:ok, _} = Plain.apply_change(workspace, owner, change)
    assert {:error, {:invalid, %{user_id: [_]}}} = Plain.apply_change(workspace, owner, change)
  end

  test "unknown attrs are rejected", %{workspace: workspace, owner: owner} do
    assert {:error, {:invalid, %{bogus: ["is not an allowed field"]}}} =
             Plain.apply_change(
               workspace,
               owner,
               {:add_manual_retirement_profile, Map.put(@attrs, :bogus, 1)}
             )
  end

  test "updates and deletes a profile", %{workspace: workspace, owner: owner} do
    {:ok, %{retirement_profiles: [profile]}} =
      Plain.apply_change(
        workspace,
        owner,
        {:add_manual_retirement_profile, Map.put(@attrs, :name, "Spouse")}
      )

    assert {:ok, %{retirement_profiles: [updated]}} =
             Plain.apply_change(
               workspace,
               owner,
               {:update_retirement_profile, profile.id, %{retirement_age: 60, name: "Partner"}}
             )

    assert %{retirement_age: 60, name: "Partner", current_age: 30} = updated

    assert {:error, {:invalid, %{retirement_age: [_]}}} =
             Plain.apply_change(
               workspace,
               owner,
               {:update_retirement_profile, profile.id, %{retirement_age: 20}}
             )

    assert {:ok, %{retirement_profiles: []}} =
             Plain.apply_change(workspace, owner, {:delete_retirement_profile, profile.id})

    assert {:error, :not_found} =
             Plain.apply_change(workspace, owner, {:delete_retirement_profile, profile.id})

    assert {:error, :not_found} =
             Plain.apply_change(
               workspace,
               owner,
               {:update_retirement_profile, Ecto.UUID.generate(), %{retirement_age: 60}}
             )

    assert {:error, :not_found} =
             Plain.apply_change(workspace, owner, {:delete_retirement_profile, "not-a-uuid"})
  end

  test "editing a member profile ignores name and claim email", %{
    workspace: workspace,
    owner: owner
  } do
    {:ok, %{retirement_profiles: [profile]}} =
      Plain.apply_change(workspace, owner, {:add_member_retirement_profile, owner.id, @attrs})

    assert {:ok, %{retirement_profiles: [updated]}} =
             Plain.apply_change(
               workspace,
               owner,
               {:update_retirement_profile, profile.id, %{name: "Hacked", current_age: 31}}
             )

    assert %{name: nil, current_age: 31} = updated
    assert updated.display_name == owner.display_name
  end

  test "profiles from another workspace are not reachable", %{workspace: workspace, owner: owner} do
    other_user =
      Accounts.get_or_create_user_from_oidc!(%{"sub" => "b", "email" => "b@example.com"})

    other = Accounts.current_workspace_for_user(other_user)

    {:ok, %{retirement_profiles: [profile]}} =
      Plain.apply_change(
        other,
        other_user,
        {:add_manual_retirement_profile, Map.put(@attrs, :name, "Elsewhere")}
      )

    assert {:error, :not_found} =
             Plain.apply_change(workspace, owner, {:delete_retirement_profile, profile.id})

    assert {:error, :not_found} =
             Plain.apply_change(
               workspace,
               owner,
               {:update_retirement_profile, profile.id, %{retirement_age: 70}}
             )

    assert {:ok, %{retirement_profiles: [_]}} = Plain.load(other)
    assert {:ok, %{retirement_profiles: []}} = Plain.load(workspace)
  end

  test "dismissing the onboarding prompt goes through update_settings", %{
    workspace: workspace,
    owner: owner
  } do
    assert {:ok, %{settings: %{retirement_onboarding_dismissed: false}}} = Plain.load(workspace)

    assert {:ok, %{settings: %{retirement_onboarding_dismissed: true}}} =
             Plain.apply_change(
               workspace,
               owner,
               {:update_settings, %{retirement_onboarding_dismissed: true}}
             )
  end
end
