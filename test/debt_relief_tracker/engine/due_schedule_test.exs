defmodule DebtReliefTracker.Engine.DueScheduleTest do
  use ExUnit.Case, async: true

  alias DebtReliefTracker.Debts.DueSchedule, as: Reference
  alias DebtReliefTracker.Engine.Days
  alias DebtReliefTracker.Engine.DueSchedule

  defp debt(attrs) do
    Map.merge(
      %{type: :installment, status: :active, auto_log_mode: :automatic, due_day: 15},
      Map.new(attrs)
    )
  end

  describe "Days" do
    test "matches Date for day counts across leap years and century boundaries" do
      for date <- [
            ~D[1970-01-01],
            ~D[1999-12-31],
            ~D[2000-02-29],
            ~D[2024-02-29],
            ~D[2100-03-01],
            ~D[2026-10-31]
          ] do
        assert Days.to_days({date.year, date.month, date.day}) == Date.diff(date, ~D[1970-01-01])
      end
    end

    test "days_in_month matches Date" do
      for year <- [1900, 2000, 2023, 2024], month <- 1..12 do
        assert Days.days_in_month(year, month) == Date.days_in_month(Date.new!(year, month, 1))
      end
    end
  end

  describe "current_cycle_due_date/2 matches the Date-based schedule" do
    test "across a sweep of days and due_days, including month-end clamping" do
      for due_day <- [1, 15, 28, 29, 30, 31], offset <- 0..400 do
        today = Date.add(~D[2023-12-20], offset)
        expected = Reference.current_cycle_due_date(%{due_day: due_day}, today)

        assert DueSchedule.current_cycle_due_date(
                 %{due_day: due_day},
                 {today.year, today.month, today.day}
               ) == {expected.year, expected.month, expected.day}
      end
    end
  end

  describe "due?/2" do
    test "mirrors the reference rules" do
      today = {2026, 10, 31}
      assert DueSchedule.due?(debt(last_due_handled_on: nil), today)
      refute DueSchedule.due?(debt(last_due_handled_on: {2026, 10, 15}), today)
      assert DueSchedule.due?(debt(last_due_handled_on: {2026, 9, 15}), today)
      refute DueSchedule.due?(debt(auto_log_mode: :off), today)
      refute DueSchedule.due?(debt(type: :revolving), today)
      refute DueSchedule.due?(debt(status: :paid_off), today)
    end
  end

  describe "missed_cycles/2" do
    test "lists every unhandled due date, oldest first" do
      cycles = DueSchedule.missed_cycles(debt(last_due_handled_on: {2026, 7, 15}), {2026, 10, 31})
      assert cycles == [{2026, 8, 15}, {2026, 9, 15}, {2026, 10, 15}]
    end

    test "never-handled debt yields only the current cycle" do
      assert DueSchedule.missed_cycles(debt(last_due_handled_on: nil), {2026, 10, 31}) ==
               [{2026, 10, 15}]
    end

    test "nothing when up to date, and clamps month-end due days" do
      assert DueSchedule.missed_cycles(debt(last_due_handled_on: {2026, 10, 15}), {2026, 10, 31}) ==
               []

      assert DueSchedule.missed_cycles(
               debt(due_day: 31, last_due_handled_on: {2026, 1, 31}),
               {2026, 3, 31}
             ) == [{2026, 2, 28}, {2026, 3, 31}]
    end

    test "caps a very long gap" do
      cycles = DueSchedule.missed_cycles(debt(last_due_handled_on: {2000, 1, 15}), {2026, 10, 31})
      assert length(cycles) == 24
      assert List.last(cycles) == {2026, 10, 15}
    end

    test "payment ids are deterministic per debt and due date" do
      assert DueSchedule.payment_id("abc", {2026, 3, 5}) == "abc:2026-03-05"
    end
  end
end
