defmodule DebtReliefTrackerWeb.Holo.RetirementBrowserTest do
  # Real-browser tests of the retirement banner, roster/form modal and the
  # retirement roadmap chart (run with `mix test --include browser`).
  use DebtReliefTracker.BrowserCase

  import DebtReliefTracker.BrowserExtras

  alias DebtReliefTracker.{Accounts, Debts}
  alias DebtReliefTrackerWeb.Holo.DashboardPage

  setup do
    workspace = Accounts.ensure_default_workspace!()
    {:ok, _} = Accounts.set_tutorial_seen(Accounts.get_default_user!(), true)

    {:ok, _} =
      Debts.create_debt(workspace, nil, %{
        "name" => "Browser Visa",
        "type" => "revolving",
        "balance" => "4500.00",
        "apr" => "12.99",
        "minimum_payment_floor" => "35.00",
        "minimum_payment_rate" => "0.02"
      })

    :ok
  end

  defp open_roster(ctx) do
    ctx
    |> visit_page(DashboardPage)
    |> click("#open-retirement-onboarding")
    |> assert_selector("#retirement-modal")
  end

  defp fill_numbers(ctx) do
    ctx
    |> fill("#retirement_profile_current_age", "35")
    |> fill("#retirement_profile_retirement_age", "65")
    |> fill("#retirement_profile_current_retirement_savings", "50000")
    |> fill("#retirement_profile_monthly_retirement_contribution", "500")
    |> fill("#retirement_profile_monthly_gross_income", "6000")
    |> fill("#retirement_profile_post_debt_investment_bp", "15")
    |> fill("#retirement_profile_expected_annual_return_bp", "7")
  end

  defp add_manual(ctx, name) do
    ctx
    |> click("#open-add-retirement-profile")
    |> assert_selector("#retirement-profile-form")
    |> click("#retirement-source-manual")
    |> fill("#retirement_profile_name", name)
    |> fill_numbers()
    |> click("#save-retirement-profile")
    |> assert_selector("#retirement-profile-list")
  end

  test "banner shows, opens the roster, and the roster closes", ctx do
    ctx
    |> visit_page(DashboardPage)
    |> assert_selector("#retirement-onboarding-banner")
    |> click("#open-retirement-onboarding")
    |> assert_selector("#retirement-empty")
    |> click("#close-retirement-modal")
    |> refute_selector("#retirement-modal")
    |> assert_selector("#retirement-onboarding-banner")
  end

  test "Escape closes the roster; Escape on the form goes back to the roster", ctx do
    ctx
    |> open_roster()
    |> press("Escape")
    |> refute_selector("#retirement-modal")
    |> open_roster()
    |> click("#open-add-retirement-profile")
    |> assert_selector("#retirement-profile-form")
    |> press("Escape")
    |> refute_selector("#retirement-profile-form")
    |> assert_selector("#retirement-empty")
  end

  test "dismissing the banner persists across reload", ctx do
    ctx
    |> visit_page(DashboardPage)
    |> click("#dismiss-retirement-banner")
    |> refute_selector("#retirement-onboarding-banner")

    visit_page(ctx, DashboardPage)
    assert_selector(ctx, "#holo-dashboard")
    refute_selector(ctx, "#retirement-onboarding-banner")
  end

  test "Skip for now closes the modal and hides the banner", ctx do
    ctx
    |> open_roster()
    |> click("#dismiss-retirement-prompt")
    |> refute_selector("#retirement-modal")
    |> refute_selector("#retirement-onboarding-banner")
  end

  test "manual profile: validation errors, then add, edit, delete", ctx do
    ctx
    |> open_roster()
    |> click("#open-add-retirement-profile")
    |> assert_selector("#retirement-profile-form")
    |> click("#save-retirement-profile")
    |> assert_text("#retirement-profile-form", "can't be blank")
    |> click("#retirement-source-manual")
    |> assert_selector("#retirement_profile_name")
    |> click("#save-retirement-profile")
    |> assert_text("#retirement-profile-form", "can't be blank")
    |> fill("#retirement_profile_name", "Pat")
    |> fill_numbers()
    |> fill("#retirement_profile_retirement_age", "30")
    |> click("#save-retirement-profile")
    |> assert_text("#retirement-profile-form", "must be greater than current age")
    |> fill("#retirement_profile_retirement_age", "abc")
    |> click("#save-retirement-profile")
    |> assert_text("#retirement-profile-form", "is invalid")
    |> fill("#retirement_profile_retirement_age", "65")
    |> fill("#retirement_profile_expected_annual_return_bp", "50")
    |> click("#save-retirement-profile")
    |> assert_text("#retirement-profile-form", "must be less than or equal to 30")
    |> fill("#retirement_profile_expected_annual_return_bp", "7")
    |> click("#save-retirement-profile")
    |> assert_selector("#retirement-profile-list")
    |> assert_text("#retirement-profile-list", "Pat")
    |> assert_text("#retirement-profile-list", "retiring at 65")
    # the banner is gone once a profile exists
    |> click("#close-retirement-modal")
    |> refute_selector("#retirement-onboarding-banner")

    profile =
      hd(
        DebtReliefTracker.Settings.list_retirement_profiles(Accounts.ensure_default_workspace!())
      )

    assert profile.name == "Pat"
    assert profile.current_age == 35
    assert Decimal.equal?(profile.post_debt_investment_pct, 15)
  end

  test "edit a profile, then remove it", ctx do
    ctx
    |> open_roster()
    |> add_manual("Sam")

    [profile] =
      DebtReliefTracker.Settings.list_retirement_profiles(Accounts.ensure_default_workspace!())

    ctx
    |> click("#edit-retirement-profile-#{profile.id}")
    |> assert_selector("#retirement-profile-form")
    |> wait_js("document.querySelector('#retirement_profile_name').value === 'Sam'")
    |> wait_js("document.querySelector('#retirement_profile_current_age').value === '35'")
    |> fill("#retirement_profile_current_age", "40")
    |> click("#save-retirement-profile")
    |> assert_text("#retirement-profile-list", "currently 40")
    |> click("#delete-retirement-profile-#{profile.id}")
    |> assert_selector("#retirement-empty")

    assert DebtReliefTracker.Settings.list_retirement_profiles(
             Accounts.ensure_default_workspace!()
           ) == []
  end

  test "member profile for the existing household member", ctx do
    ctx
    |> open_roster()
    |> click("#open-add-retirement-profile")
    |> assert_selector("#retirement-profile-form")

    # the default user is a confirmed member, so the picker is offered
    assert_selector(ctx, "#retirement_profile_user_id")

    ctx
    |> fill_numbers()
    |> click("#save-retirement-profile")
    |> assert_selector("#retirement-profile-list")
  end

  test "retirement roadmap chart: message without a profile, canvas once one exists", ctx do
    ctx
    |> visit_page(DashboardPage)
    |> click("#chart-type-retirement_roadmap")
    |> assert_selector("#plan-chart-message")
    |> click("#open-retirement-onboarding")
    |> add_manual("Casey")
    |> click("#close-retirement-modal")
    |> assert_selector("#plan-chart canvas")
    |> refute_selector("#plan-chart-message")
  end
end
