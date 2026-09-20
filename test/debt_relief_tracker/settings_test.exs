defmodule DebtReliefTracker.SettingsTest do
  use DebtReliefTracker.DataCase

  alias DebtReliefTracker.{Accounts, Settings}

  @profile_attrs %{
    "current_age" => "30",
    "retirement_age" => "65",
    "current_retirement_savings" => "1000",
    "monthly_retirement_contribution" => "100",
    "monthly_gross_income" => "4000",
    "post_debt_investment_pct" => "15.0",
    "expected_annual_return_pct" => "7.0"
  }

  defp owner_and_workspace do
    owner = Accounts.get_or_create_user_from_oidc!(%{"sub" => "a", "email" => "a@example.com"})
    {owner, Accounts.current_workspace_for_user(owner)}
  end

  describe "retirement profiles" do
    test "add_member_retirement_profile/3 links a confirmed member, one profile per member" do
      {owner, workspace} = owner_and_workspace()

      assert {:ok, profile} =
               Settings.add_member_retirement_profile(workspace, owner, @profile_attrs)

      assert profile.user_id == owner.id
      assert profile.name == nil

      assert {:error, changeset} =
               Settings.add_member_retirement_profile(workspace, owner, @profile_attrs)

      assert %{user_id: ["has already been taken"]} = errors_on(changeset)
    end

    test "add_manual_retirement_profile/2 creates a profile for someone with no account" do
      {_owner, workspace} = owner_and_workspace()

      attrs = Map.put(@profile_attrs, "name", "Spouse")

      assert {:ok, profile} = Settings.add_manual_retirement_profile(workspace, attrs)
      assert profile.user_id == nil
      assert profile.name == "Spouse"

      assert {:error, changeset} =
               Settings.add_manual_retirement_profile(workspace, @profile_attrs)

      assert %{name: ["can't be blank"]} = errors_on(changeset)
    end

    test "add_manual_retirement_profile/2 rejects a second manual entry with the same claim email" do
      {_owner, workspace} = owner_and_workspace()

      attrs =
        Map.merge(@profile_attrs, %{"name" => "Spouse", "claim_email" => "spouse@example.com"})

      assert {:ok, _profile} = Settings.add_manual_retirement_profile(workspace, attrs)

      assert {:error, changeset} = Settings.add_manual_retirement_profile(workspace, attrs)
      assert %{claim_email: ["has already been taken"]} = errors_on(changeset)
    end

    test "list_retirement_profiles/1 returns every profile for the workspace, oldest first" do
      {owner, workspace} = owner_and_workspace()

      {:ok, member_profile} =
        Settings.add_member_retirement_profile(workspace, owner, @profile_attrs)

      {:ok, manual_profile} =
        Settings.add_manual_retirement_profile(
          workspace,
          Map.put(@profile_attrs, "name", "Spouse")
        )

      assert [first, second] = Settings.list_retirement_profiles(workspace)
      assert first.id == member_profile.id
      assert second.id == manual_profile.id
      assert first.user.id == owner.id
    end

    test "update_retirement_profile/2 edits numbers, and a manual profile's name" do
      {owner, workspace} = owner_and_workspace()

      {:ok, member_profile} =
        Settings.add_member_retirement_profile(workspace, owner, @profile_attrs)

      assert {:ok, updated} =
               Settings.update_retirement_profile(member_profile, %{
                 "monthly_gross_income" => "5000"
               })

      assert Decimal.equal?(updated.monthly_gross_income, Decimal.new("5000"))
      assert updated.name == nil

      {:ok, manual_profile} =
        Settings.add_manual_retirement_profile(
          workspace,
          Map.put(@profile_attrs, "name", "Spouse")
        )

      assert {:ok, updated_manual} =
               Settings.update_retirement_profile(manual_profile, %{"name" => "Partner"})

      assert updated_manual.name == "Partner"
    end

    test "delete_retirement_profile/1 removes it" do
      {owner, workspace} = owner_and_workspace()
      {:ok, profile} = Settings.add_member_retirement_profile(workspace, owner, @profile_attrs)

      assert {:ok, _} = Settings.delete_retirement_profile(profile)
      assert Settings.list_retirement_profiles(workspace) == []
    end

    test "claim_retirement_profiles/1 links a manual profile once its email joins the workspace" do
      {owner, workspace} = owner_and_workspace()

      attrs =
        Map.merge(@profile_attrs, %{"name" => "Spouse", "claim_email" => "spouse@example.com"})

      {:ok, manual_profile} = Settings.add_manual_retirement_profile(workspace, attrs)

      {:ok, _member} =
        Accounts.share_workspace_with_email(workspace, "spouse@example.com", owner)

      spouse =
        Accounts.get_or_create_user_from_oidc!(%{
          "sub" => "spouse-sub",
          "email" => "spouse@example.com"
        })

      assert [claimed] = Settings.list_retirement_profiles(workspace)
      assert claimed.id == manual_profile.id
      assert claimed.user_id == spouse.id
      assert claimed.name == nil
      assert claimed.claim_email == nil
    end

    test "claim_retirement_profiles/1 does not claim a matching email that isn't a member of that workspace" do
      {_owner, workspace} = owner_and_workspace()

      attrs =
        Map.merge(@profile_attrs, %{"name" => "Spouse", "claim_email" => "spouse@example.com"})

      {:ok, _manual_profile} = Settings.add_manual_retirement_profile(workspace, attrs)

      # Logs in, but was never invited/added to this workspace.
      Accounts.get_or_create_user_from_oidc!(%{
        "sub" => "unrelated",
        "email" => "spouse@example.com"
      })

      assert [profile] = Settings.list_retirement_profiles(workspace)
      assert profile.user_id == nil
    end

    test "unlink_retirement_profile/2 downgrades a linked profile back to manual" do
      {owner, workspace} = owner_and_workspace()
      member = Accounts.get_or_create_user_from_oidc!(%{"sub" => "b", "email" => "b@example.com"})
      {:ok, _} = Accounts.share_workspace_with_email(workspace, "b@example.com", owner)

      {:ok, profile} = Settings.add_member_retirement_profile(workspace, member, @profile_attrs)

      assert :ok = Settings.unlink_retirement_profile(workspace, member)

      assert [reloaded] = Settings.list_retirement_profiles(workspace)
      assert reloaded.id == profile.id
      assert reloaded.user_id == nil
      assert reloaded.name == member.display_name
      assert reloaded.claim_email == member.email
    end
  end

  describe "get_site_settings/0" do
    test "creates a default row on first call, idempotently" do
      site_settings1 = Settings.get_site_settings()
      site_settings2 = Settings.get_site_settings()

      assert site_settings1.id == site_settings2.id
      assert site_settings1.welcome_emails_enabled
    end
  end

  describe "update_site_settings/2" do
    test "updates the site identity fields" do
      site_settings = Settings.get_site_settings()

      assert {:ok, updated} =
               Settings.update_site_settings(site_settings, %{
                 "site_name" => "Our Tracker",
                 "from_name" => "Our Tracker",
                 "from_email" => "hello@example.com",
                 "welcome_emails_enabled" => "false"
               })

      assert updated.site_name == "Our Tracker"
      assert updated.from_email == "hello@example.com"
      refute updated.welcome_emails_enabled
    end
  end
end
