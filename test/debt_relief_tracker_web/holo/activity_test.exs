defmodule DebtReliefTrackerWeb.Holo.ActivityTest do
  use ExUnit.Case, async: true

  alias DebtReliefTrackerWeb.Holo.Activity

  @debts [%{id: "d1", name: "Auto Loan (example)"}]
  @actors %{"u1" => "Sam"}

  defp entry(action, attrs \\ %{}) do
    Map.merge(
      %{
        id: "e1",
        action: action,
        debt_id: "d1",
        user_id: "u1",
        metadata: %{},
        inserted_at: "2026-07-11T14:03:09.123456Z"
      },
      attrs
    )
  end

  describe "description/4" do
    test "debt lifecycle entries name the actor and the debt" do
      assert Activity.description(entry("debt_added"), @debts, @actors, "USD") ==
               "Sam added Auto Loan (example)"

      assert Activity.description(entry("debt_updated"), @debts, @actors, "USD") ==
               "Sam updated Auto Loan (example)"

      assert Activity.description(entry("debt_paid_off"), @debts, @actors, "USD") ==
               "Sam marked Auto Loan (example) as paid off"

      assert Activity.description(entry("debt_deleted"), @debts, @actors, "USD") ==
               "Sam deleted Auto Loan (example)"
    end

    test "payments render the amount from the string metadata as money" do
      e = entry("payment_logged", %{metadata: %{"amount" => "1250.50"}})

      assert Activity.description(e, @debts, @actors, "USD") ==
               "Sam logged a $1,250.50 payment on Auto Loan (example)"

      auto = entry("payment_auto_logged", %{user_id: nil, metadata: %{"amount" => "50.00"}})

      assert Activity.description(auto, @debts, @actors, "EUR") ==
               "Auto-logged a €50.00 payment on Auto Loan (example)"
    end

    test "skipped due payment" do
      assert Activity.description(entry("due_payment_skipped"), @debts, @actors, "USD") ==
               "Sam skipped this month's payment on Auto Loan (example)"
    end

    test "unknown actor reads as Someone; deleted debt falls back to the recorded name, then a generic one" do
      deleted =
        entry("debt_deleted", %{debt_id: nil, user_id: "gone", metadata: %{"name" => "Old Card"}})

      assert Activity.description(deleted, @debts, @actors, "USD") == "Someone deleted Old Card"

      nameless = entry("debt_deleted", %{debt_id: nil})
      assert Activity.description(nameless, @debts, @actors, "USD") == "Sam deleted a debt"
    end

    test "a payment without an amount doesn't crash" do
      e = entry("payment_logged", %{metadata: %{}})

      assert Activity.description(e, @debts, @actors, "USD") =~ "an unknown amount"
    end
  end

  describe "amount_cents/1" do
    test "parses decimal strings with integer math" do
      assert Activity.amount_cents("50") == 5000
      assert Activity.amount_cents("50.5") == 5050
      assert Activity.amount_cents("50.00") == 5000
      assert Activity.amount_cents("0.07") == 7
      assert Activity.amount_cents("12.345") == 1235
      assert Activity.amount_cents("-3.10") == -310
    end

    test "garbage is nil" do
      assert Activity.amount_cents(nil) == nil
      assert Activity.amount_cents("") == nil
      assert Activity.amount_cents("abc") == nil
      assert Activity.amount_cents("1.2.3") == nil
    end
  end

  describe "format_when/1" do
    test "matches the LiveView's \"%b %d, %Y %I:%M %p\"" do
      assert Activity.format_when("2026-07-11T14:03:09.123456Z") == "Jul 11, 2026 02:03 PM"
      assert Activity.format_when("2026-01-05T00:07:00Z") == "Jan 05, 2026 12:07 AM"
      assert Activity.format_when("2026-12-31T12:00:00") == "Dec 31, 2026 12:00 PM"
    end

    test "nil is blank" do
      assert Activity.format_when(nil) == ""
    end
  end
end
