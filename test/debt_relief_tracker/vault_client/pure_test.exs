defmodule DebtReliefTracker.VaultClient.PureTest do
  use ExUnit.Case, async: true

  alias DebtReliefTracker.VaultClient.{Delay, Recovery, SaveLoop, Strength}

  describe "Strength" do
    test "empty, short and too-common passphrases" do
      assert %{level: 0, long_enough?: false, acceptable?: false} = Strength.estimate("")
      assert %{long_enough?: false, acceptable?: false} = Strength.estimate("Abc123!x")
      assert %{level: 0, acceptable?: false} = Strength.estimate("aaaaaaaaaaaaaaaa")
      assert %{level: 0} = Strength.estimate("PASSWORD")
      assert %{level: 0, acceptable?: false} = Strength.estimate("123456789012")
    end

    test "length and variety raise the level" do
      weak = Strength.estimate("abcdefghijkl")
      fair = Strength.estimate("correct horse battery")
      good = Strength.estimate("correct horse battery staple 42")
      strong = Strength.estimate("Tr0ub4dor&3 correct horse battery staple!")
      assert weak.level <= fair.level
      assert fair.level <= good.level
      assert good.level <= strong.level
      assert strong.level == 4
      assert weak.long_enough? and fair.acceptable? and strong.acceptable?
    end

    test "counts characters, not bytes" do
      assert Strength.estimate("äöüäöüäöüäöü").length == 12
      assert Strength.estimate("pässphrase-ünïcode").long_enough?
    end

    test "min length is 12" do
      assert Strength.min_length() == 12
      assert Strength.estimate("correct horse").long_enough?
      refute Strength.estimate("short phras").long_enough?
    end
  end

  describe "Delay" do
    test "schedule: free for 3 attempts, then 1 2 4 8 16 30 30" do
      assert Enum.map(0..9, &Delay.seconds/1) == [0, 0, 0, 1, 2, 4, 8, 16, 30, 30]
      assert Delay.seconds(1000) == 30
    end

    test "failed/2 and remaining_seconds/2" do
      s = Enum.reduce(1..3, Delay.new(), fn _, s -> Delay.failed(s, 10_000) end)
      assert s.failures == 3
      assert Delay.remaining_seconds(s, 10_000) == 1
      assert Delay.remaining_seconds(s, 10_999) == 1
      assert Delay.remaining_seconds(s, 11_000) == 0
      assert Delay.blocked?(s, 10_500)
      s = Delay.failed(s, 11_000)
      assert Delay.remaining_seconds(s, 11_000) == 2
      refute Delay.blocked?(Delay.new(), 0)
    end
  end

  describe "Recovery" do
    @key "ABCD-EFGH-IJKL-MNOP-QRST-UVWX-YZ23-4567-ABCD-EFGH-IJKL-MNOP-QRST-WXYZ"

    test "groups and final group" do
      assert length(Recovery.groups(@key)) == 14
      assert Recovery.final_group(@key) == "WXYZ"
    end

    test "acknowledgment is the final group, tolerant of case and spacing" do
      assert Recovery.ack_ok?(@key, "WXYZ")
      assert Recovery.ack_ok?(@key, " wxyz ")
      assert Recovery.ack_ok?(@key, "w-x-y-z")
      refute Recovery.ack_ok?(@key, "WXYY")
      refute Recovery.ack_ok?(@key, "")
      refute Recovery.ack_ok?(@key, "QRST")
      refute Recovery.ack_ok?(@key, "QRST-WXYZ")
      refute Recovery.ack_ok?(@key, nil)
    end
  end

  describe "SaveLoop" do
    test "edit -> debounce token -> flush -> saved" do
      s = SaveLoop.new(3)
      {s, t1} = SaveLoop.changed(s)
      {s, t2} = SaveLoop.changed(s)
      assert s.status == :dirty and s.dirty?
      refute SaveLoop.flush_due?(s, t1), "an older timer is superseded"
      assert SaveLoop.flush_due?(s, t2)
      s = SaveLoop.flush_started(s)
      assert s.status == :saving and s.inflight?
      refute SaveLoop.flush_due?(s, t2), "never two saves in flight"

      assert {%{status: :saved, dirty?: false, base_rev: 4, retries: 0}, :done} =
               SaveLoop.saved(s, 4)
    end

    test "edits during a save keep the loop dirty and ask for another flush" do
      {s, _} = SaveLoop.changed(SaveLoop.new(1))
      s = SaveLoop.flush_started(s)
      {s, t} = SaveLoop.changed(s)
      assert s.status == :saving
      {s, :flush_again} = SaveLoop.saved(s, 2)
      assert s.dirty? and s.status == :dirty and s.base_rev == 2
      assert SaveLoop.flush_due?(s, t)
    end

    test "conflict: rebase on the server rev, back off, bounded retries, never drops the change" do
      {s, _} = SaveLoop.changed(SaveLoop.new(1))
      s = SaveLoop.flush_started(s)
      {s, {:retry, 500}} = SaveLoop.conflicted(s, 5)
      assert %{base_rev: 5, status: :merged, dirty?: true, inflight?: false} = s

      s =
        Enum.reduce(1..5, s, fn _, s ->
          s = SaveLoop.flush_started(s)
          {s, {:retry, _}} = SaveLoop.conflicted(s, 6)
          s
        end)

      assert s.retries == 6
      {s, :give_up} = SaveLoop.conflicted(SaveLoop.flush_started(s), 7)
      assert s.status == :failed and s.dirty?, "a dirty change survives giving up"
      assert SaveLoop.unsaved?(s)
      s = SaveLoop.reset_retries(s)
      assert s.status == :dirty and s.retries == 0
    end

    test "offline failure backs off and retries" do
      {s, _} = SaveLoop.changed(SaveLoop.new(1))
      {s, {:retry, 500}} = SaveLoop.failed(SaveLoop.flush_started(s))
      {s, {:retry, 1000}} = SaveLoop.failed(SaveLoop.flush_started(s))
      assert s.status == :offline and s.dirty?
      assert SaveLoop.backoff_ms(20) == 30_000
    end

    test "remote merge from a refetch" do
      s = SaveLoop.new(2)
      {s, _} = SaveLoop.remote_merged(s, 4, false)
      assert %{base_rev: 4, status: :merged, dirty?: false} = s
      refute SaveLoop.unsaved?(s)
      {s, token} = SaveLoop.remote_merged(s, 5, true)
      assert s.dirty? and s.status == :dirty and SaveLoop.flush_due?(s, token)
    end
  end

  describe "SaveLoop.stalled (undecryptable conflict reply)" do
    test "releases the in-flight flag, keeps the edits dirty, and allows a retry" do
      s = SaveLoop.new(3)
      {s, token} = SaveLoop.changed(s)
      assert SaveLoop.flush_due?(s, token)
      s = SaveLoop.flush_started(s)
      assert s.inflight? and SaveLoop.unsaved?(s)
      refute SaveLoop.flush_due?(s, token)

      s = SaveLoop.stalled(s)
      assert s.status == :failed and s.dirty? and not s.inflight?
      assert SaveLoop.unsaved?(s)

      # Manual retry: a new flush is due again (this was the wedge).
      s = SaveLoop.reset_retries(s)
      {s, token} = SaveLoop.changed(s)
      assert SaveLoop.flush_due?(s, token)
    end

    test "a clean loop stays clean" do
      s = SaveLoop.stalled(SaveLoop.new(1))
      refute s.dirty?
      refute s.inflight?
    end
  end
end
