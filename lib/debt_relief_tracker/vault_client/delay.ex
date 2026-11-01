defmodule DebtReliefTracker.VaultClient.Delay do
  @moduledoc """
  Client-side throttling of unlock attempts. After the third consecutive
  failure each further failure doubles the wait: 1 s, 2 s, 4 s, ... capped at
  30 s. State is `%{failures, blocked_until_ms}`; it lives in UI memory only
  (a determined attacker can reload the page -- the real protection against
  offline guessing is Argon2id and the passphrase, not this delay; it stops
  casual brute-forcing through the UI and mistyping loops).
  """

  @free_attempts 3
  @cap_seconds 30

  def new, do: %{failures: 0, blocked_until_ms: 0}

  @doc "Seconds to wait after `failures` consecutive failures."
  def seconds(failures) when failures < @free_attempts, do: 0

  def seconds(failures) do
    # 2^(failures - 3), capped; guard the shift so huge counts cannot overflow.
    n = min(failures - @free_attempts, 5)
    min(pow2(n), @cap_seconds)
  end

  defp pow2(0), do: 1
  defp pow2(n), do: 2 * pow2(n - 1)

  @doc "Records a failed attempt at `now_ms`."
  def failed(%{failures: failures} = state, now_ms) do
    failures = failures + 1
    %{state | failures: failures, blocked_until_ms: now_ms + seconds(failures) * 1000}
  end

  @doc "Whole seconds still to wait at `now_ms` (0 = free to try)."
  def remaining_seconds(%{blocked_until_ms: until}, now_ms) when until > now_ms,
    do: div(until - now_ms + 999, 1000)

  def remaining_seconds(_state, _now_ms), do: 0

  def blocked?(state, now_ms), do: remaining_seconds(state, now_ms) > 0
end
