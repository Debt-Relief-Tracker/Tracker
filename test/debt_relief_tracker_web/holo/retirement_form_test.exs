defmodule DebtReliefTrackerWeb.Holo.RetirementFormTest do
  use ExUnit.Case, async: true

  alias DebtReliefTrackerWeb.Holo.RetirementForm

  @valid %{
    user_id: "",
    name: "Spouse",
    claim_email: "spouse@example.com",
    current_age: "28",
    retirement_age: "60",
    current_retirement_savings: "500",
    monthly_retirement_contribution: "50.5",
    monthly_gross_income: "3000",
    post_debt_investment_bp: "15",
    expected_annual_return_bp: "7.25"
  }

  describe "parse_scaled/2" do
    test "parses decimals into scaled integers, rounding half up" do
      assert RetirementForm.parse_scaled("12", 2) == {:ok, 1200}
      assert RetirementForm.parse_scaled(" 12.5 ", 2) == {:ok, 1250}
      assert RetirementForm.parse_scaled("0.05", 2) == {:ok, 5}
      assert RetirementForm.parse_scaled(".5", 2) == {:ok, 50}
      assert RetirementForm.parse_scaled("1.005", 2) == {:ok, 101}
      assert RetirementForm.parse_scaled("1.004", 2) == {:ok, 100}
      assert RetirementForm.parse_scaled("007", 0) == {:ok, 7}
      assert RetirementForm.parse_scaled("-3.5", 2) == {:ok, -350}
    end

    test "reports blanks and junk" do
      assert RetirementForm.parse_scaled("", 2) == :blank
      assert RetirementForm.parse_scaled("   ", 2) == :blank
      for junk <- ["abc", "1.2.3", ".", "-", "1e5", "$5", "1,000"] do
        assert RetirementForm.parse_scaled(junk, 2) == :error, junk
      end
    end
  end

  test "cents_to_text/1 and bp_to_text/1 round trip with parse_scaled/2" do
    assert RetirementForm.cents_to_text(1_000_050) == "10000.50"
    assert RetirementForm.cents_to_text(5) == "0.05"
    assert RetirementForm.cents_to_text(0) == "0.00"

    assert RetirementForm.bp_to_text(750) == "7.5"
    assert RetirementForm.bp_to_text(1500) == "15"
    assert RetirementForm.bp_to_text(725) == "7.25"
    assert RetirementForm.bp_to_text(705) == "7.05"
    assert RetirementForm.bp_to_text(0) == "0"

    for n <- [0, 5, 50, 99, 100, 12_345, 1_000_050] do
      assert {:ok, ^n} = n |> RetirementForm.cents_to_text() |> RetirementForm.parse_scaled(2)
      assert {:ok, ^n} = n |> RetirementForm.bp_to_text() |> RetirementForm.parse_scaled(2)
    end
  end

  describe "build_change/2" do
    test "a manual add becomes a Storage change in cents and basis points" do
      assert {:ok, {:add_manual_retirement_profile, attrs}} =
               RetirementForm.build_change({:add, "manual"}, @valid)

      assert attrs == %{
               name: "Spouse",
               claim_email: "spouse@example.com",
               current_age: 28,
               retirement_age: 60,
               current_retirement_savings: 50_000,
               monthly_retirement_contribution: 5_050,
               monthly_gross_income: 300_000,
               post_debt_investment_bp: 1500,
               expected_annual_return_bp: 725
             }
    end

    test "a blank claim email becomes nil" do
      form = %{@valid | claim_email: "  "}
      assert {:ok, {_, %{claim_email: nil}}} = RetirementForm.build_change({:add, "manual"}, form)
    end

    test "a member add carries the picked user id and no name" do
      form = %{@valid | user_id: "user-1"}

      assert {:ok, {:add_member_retirement_profile, "user-1", attrs}} =
               RetirementForm.build_change({:add, "member"}, form)

      refute Map.has_key?(attrs, :name)
      assert attrs.current_age == 28

      assert {:error, %{user_id: ["can't be blank"]}} =
               RetirementForm.build_change({:add, "member"}, @valid)
    end

    test "editing a member profile leaves name and email out; a manual one sends them" do
      assert {:ok, {:update_retirement_profile, "p1", attrs}} =
               RetirementForm.build_change({:update, "p1", false}, @valid)

      refute Map.has_key?(attrs, :name)

      assert {:ok, {:update_retirement_profile, "p1", %{name: "Spouse"}}} =
               RetirementForm.build_change({:update, "p1", true}, @valid)
    end

    test "rejects a retirement age that isn't after the current age" do
      form = %{@valid | current_age: "40", retirement_age: "40"}

      assert {:error, %{retirement_age: ["must be greater than current age"]}} =
               RetirementForm.build_change({:add, "manual"}, form)
    end

    test "mirrors the changeset's required and range messages" do
      form = %{
        @valid
        | name: "",
          current_age: "",
          retirement_age: "130",
          monthly_gross_income: "-1",
          post_debt_investment_bp: "101",
          expected_annual_return_bp: "31"
      }

      assert {:error, errors} = RetirementForm.build_change({:add, "manual"}, form)

      assert errors == %{
               name: ["can't be blank"],
               current_age: ["can't be blank"],
               retirement_age: ["must be less than or equal to 120"],
               monthly_gross_income: ["must be greater than or equal to 0"],
               post_debt_investment_bp: ["must be less than or equal to 100"],
               expected_annual_return_bp: ["must be less than or equal to 30"]
             }
    end

    test "non-numeric text and fractional ages are invalid" do
      form = %{@valid | current_age: "28.5", current_retirement_savings: "lots"}

      assert {:error, %{current_age: ["is invalid"], current_retirement_savings: ["is invalid"]}} =
               RetirementForm.build_change({:add, "manual"}, form)
    end
  end

  test "from_profile/1 fills the form from a snapshot profile" do
    profile = %{
      user_id: nil,
      name: "Spouse",
      claim_email: nil,
      current_age: 28,
      retirement_age: 60,
      current_retirement_savings: 50_000,
      monthly_retirement_contribution: 5_050,
      monthly_gross_income: 300_000,
      post_debt_investment_bp: 1500,
      expected_annual_return_bp: 725
    }

    form = RetirementForm.from_profile(profile)
    assert form.name == "Spouse"
    assert form.claim_email == ""
    assert form.current_retirement_savings == "500.00"
    assert form.post_debt_investment_bp == "15"
    assert form.expected_annual_return_bp == "7.25"

    assert {:ok, {:update_retirement_profile, "p", attrs}} =
             RetirementForm.build_change({:update, "p", true}, form)

    assert attrs.current_retirement_savings == 50_000
    assert attrs.expected_annual_return_bp == 725
  end

  test "errors_from/1 flattens Storage errors" do
    assert RetirementForm.errors_from({:invalid, %{name: ["bad"]}}) == %{name: ["bad"]}
    assert %{base: [_]} = RetirementForm.errors_from(:not_found)
  end
end
