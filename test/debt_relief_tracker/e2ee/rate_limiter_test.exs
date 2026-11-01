defmodule DebtReliefTracker.E2EE.RateLimiterTest do
  use ExUnit.Case, async: false

  alias DebtReliefTracker.E2EE.RateLimiter

  setup do
    RateLimiter.reset()
    :ok
  end

  defp take(key, n, opts) do
    for _ <- 1..n, do: RateLimiter.check(key, opts)
  end

  test "allows up to capacity then limits" do
    opts = [now: 0, capacity: 3, refill_per_sec: 1]
    assert take("w", 3, opts) == [:ok, :ok, :ok]
    assert RateLimiter.check("w", opts) == {:error, :rate_limited}
  end

  test "refills over time, never above capacity" do
    opts = [capacity: 2, refill_per_sec: 1]
    assert take("w", 2, [now: 0] ++ opts) == [:ok, :ok]
    assert RateLimiter.check("w", [now: 500] ++ opts) == {:error, :rate_limited}
    assert RateLimiter.check("w", [now: 1_000] ++ opts) == :ok
    assert RateLimiter.check("w", [now: 1_000] ++ opts) == {:error, :rate_limited}
    # a long idle period refills to capacity only
    assert take("w", 3, [now: 1_000_000] ++ opts) == [:ok, :ok, {:error, :rate_limited}]
  end

  test "buckets are per key" do
    opts = [now: 0, capacity: 1, refill_per_sec: 1]
    assert RateLimiter.check("a", opts) == :ok
    assert RateLimiter.check("a", opts) == {:error, :rate_limited}
    assert RateLimiter.check("b", opts) == :ok
  end

  test "concurrent callers cannot overspend one bucket" do
    opts = [now: 0, capacity: 10, refill_per_sec: 0]

    results =
      1..50
      |> Enum.map(fn _ -> Task.async(fn -> RateLimiter.check("w", opts) end) end)
      |> Task.await_many()

    assert Enum.count(results, &(&1 == :ok)) == 10
  end
end
