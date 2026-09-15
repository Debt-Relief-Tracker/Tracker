defmodule DebtReliefTracker.Debts.DueScheduleTest do
  use ExUnit.Case, async: true

  alias DebtReliefTracker.Debts.DueSchedule

  defp installment(attrs) do
    Map.merge(
      %{
        type: :installment,
        status: :active,
        auto_log_mode: :confirm,
        due_day: 15,
        last_due_handled_on: nil
      },
      Map.new(attrs)
    )
  end

  describe "current_cycle_due_date/2" do
    test "mid-month case: this month's due date when today is past it" do
      debt = installment(due_day: 15)
      assert DueSchedule.current_cycle_due_date(debt, ~D[2026-07-20]) == ~D[2026-07-15]
    end

    test "falls back to last month's due date when today is before this month's" do
      debt = installment(due_day: 20)
      assert DueSchedule.current_cycle_due_date(debt, ~D[2026-07-05]) == ~D[2026-06-20]
    end

    test "clamps due_day: 31 to the actual last day of a 30-day month" do
      debt = installment(due_day: 31)
      assert DueSchedule.current_cycle_due_date(debt, ~D[2026-09-30]) == ~D[2026-09-30]
    end

    test "clamps due_day: 31 to February 28 in a non-leap year" do
      debt = installment(due_day: 31)
      assert DueSchedule.current_cycle_due_date(debt, ~D[2027-02-28]) == ~D[2027-02-28]
    end

    test "clamps due_day: 31 to February 29 in a leap year" do
      debt = installment(due_day: 31)
      assert DueSchedule.current_cycle_due_date(debt, ~D[2028-02-29]) == ~D[2028-02-29]
    end
  end

  describe "due?/2" do
    test "true when never handled and the due date has passed" do
      debt = installment(due_day: 15, last_due_handled_on: nil)
      assert DueSchedule.due?(debt, ~D[2026-07-20])
    end

    test "false when already handled for the current cycle" do
      debt = installment(due_day: 15, last_due_handled_on: ~D[2026-07-15])
      refute DueSchedule.due?(debt, ~D[2026-07-20])
    end

    test "true again once a new cycle is due, even if a much older cycle was last handled (missed checks catch up)" do
      debt = installment(due_day: 15, last_due_handled_on: ~D[2026-05-15])
      assert DueSchedule.due?(debt, ~D[2026-07-20])
    end

    test "false when auto_log_mode is :off" do
      debt = installment(due_day: 15, auto_log_mode: :off, last_due_handled_on: nil)
      refute DueSchedule.due?(debt, ~D[2026-07-20])
    end

    test "false for revolving debts regardless of other fields" do
      debt = installment(due_day: 15, type: :revolving, last_due_handled_on: nil)
      refute DueSchedule.due?(debt, ~D[2026-07-20])
    end

    test "false for paid-off debts" do
      debt = installment(due_day: 15, status: :paid_off, last_due_handled_on: nil)
      refute DueSchedule.due?(debt, ~D[2026-07-20])
    end

    test "true for :automatic mode too, not just :confirm" do
      debt = installment(due_day: 15, auto_log_mode: :automatic, last_due_handled_on: nil)
      assert DueSchedule.due?(debt, ~D[2026-07-20])
    end
  end
end
