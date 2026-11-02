defmodule DebtReliefTrackerWeb.Holo.VaultFlowEnforcementTest do
  use ExUnit.Case, async: true

  alias DebtReliefTracker.Crypto
  alias DebtReliefTrackerWeb.Holo.VaultFlow
  alias Hologram.Component

  defp component do
    vault = VaultFlow.new_vault([], idle_ms: 1000, test_hook: false)
    %Component{state: %{vault: vault}}
  end

  describe "passphrase rule" do
    test "too short and weak passphrases are rejected before any wrap" do
      assert {:error, :passphrase_too_short} = VaultFlow.check_new_passphrase("")
      assert {:error, :passphrase_too_short} = VaultFlow.check_new_passphrase("elevenchars")
      assert {:error, :passphrase_weak} = VaultFlow.check_new_passphrase("aaaaaaaaaaaaaaaa")
      assert :ok = VaultFlow.check_new_passphrase("correct horse battery")
    end

    test "Crypto.wrap_passphrase refuses a short passphrase without touching the facade" do
      assert {:error, :passphrase_too_short} = Crypto.wrap_passphrase("h", "short", "ws", "w1")

      assert {:error, :passphrase_too_short} =
               Crypto.wrap_passphrase("h", "elevenchars", "ws", "w1")
    end
  end

  describe "unlock throttle (page state)" do
    test "free for three failures, then exponential, then reset on success" do
      c = component()
      assert VaultFlow.unlock_wait(c.state.vault, 0) == 0

      c = Enum.reduce(1..3, c, fn _, c -> VaultFlow.unlock_failed(c, 10_000) end)
      assert VaultFlow.unlock_wait(c.state.vault, 10_000) == 1

      c = VaultFlow.unlock_failed(c, 11_000)
      assert VaultFlow.unlock_wait(c.state.vault, 11_000) == 2
      c = VaultFlow.unlock_failed(c, 13_000)
      assert VaultFlow.unlock_wait(c.state.vault, 13_000) == 4
      assert VaultFlow.unlock_wait(c.state.vault, 15_000) == 2
      assert VaultFlow.unlock_wait(c.state.vault, 17_000) == 0

      # a successful unlock resets it (opened/2 merges a fresh Delay)
      assert c.state.vault.unlock_delay.failures == 5
      fresh = DebtReliefTracker.VaultClient.Delay.new()
      assert VaultFlow.new_vault([], idle_ms: 1, test_hook: false).unlock_delay == fresh
    end
  end
end
