defmodule DebtReliefTracker.E2EE.RateLimiter do
  @moduledoc """
  In-memory per-key token bucket for the vault commands (no dependency; ETS
  owned by this GenServer). One bucket per workspace id: `capacity` tokens,
  refilling `refill_per_sec` per second; each call costs one token. State is
  per node and lost on restart, which is fine for abuse limiting.

  The bucket arithmetic runs inside the GenServer, so concurrent callers for
  one key cannot double-spend; the ETS table is only a place to keep state.
  Time is in milliseconds, tokens in milli-tokens (integers throughout).
  """

  use GenServer

  @table __MODULE__
  @capacity 30
  @refill_per_sec 1

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Takes a token for `key`: `:ok` or `{:error, :rate_limited}`."
  def check(key, opts \\ []) do
    now = Keyword.get(opts, :now, System.monotonic_time(:millisecond))
    capacity = Keyword.get(opts, :capacity, @capacity)
    refill = Keyword.get(opts, :refill_per_sec, @refill_per_sec)
    GenServer.call(__MODULE__, {:check, key, now, capacity, refill})
  end

  @doc false
  def reset, do: GenServer.call(__MODULE__, :reset)

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :set, :protected, read_concurrency: true])
    {:ok, nil}
  end

  @impl true
  def handle_call({:check, key, now, capacity, refill}, _from, state) do
    cap_milli = capacity * 1000

    {tokens, last} =
      case :ets.lookup(@table, key) do
        [{^key, tokens, last}] -> {tokens, last}
        [] -> {cap_milli, now}
      end

    # refill_per_sec tokens/s == refill_per_sec milli-tokens/ms
    tokens = min(cap_milli, tokens + max(now - last, 0) * refill)

    if tokens >= 1000 do
      :ets.insert(@table, {key, tokens - 1000, now})
      {:reply, :ok, state}
    else
      :ets.insert(@table, {key, tokens, now})
      {:reply, {:error, :rate_limited}, state}
    end
  end

  def handle_call(:reset, _from, state) do
    :ets.delete_all_objects(@table)
    {:reply, :ok, state}
  end
end
