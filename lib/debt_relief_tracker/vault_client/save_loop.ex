defmodule DebtReliefTracker.VaultClient.SaveLoop do
  @moduledoc """
  The pure state machine of the save/sync loop (ADR 0007, "Save/sync loop").
  The page owns the effects (encrypt, `save_vault`, merge); this module owns
  the decisions, so they can be tested without a browser.

      status:  :idle | :dirty | :saving | :saved | :merged | :offline | :failed
      fields:  base_rev   last server revision this replica is based on
               seq        counts local changes
               flushed_seq  value of seq when the in-flight save started
               inflight?  a save_vault is on the wire
               retries    consecutive failed/conflicted attempts
               dirty?     local changes not yet confirmed saved

  Transitions:

    * `changed/1`      local edit: dirty, seq+1; returns a flush TOKEN (the new
                       seq). A flush runs only if its token is still the
                       latest (a debounce: later edits supersede earlier timers).
    * `flush_due?/2`   token is current, nothing in flight, still dirty.
    * `flush_started/1` marks a save in flight.
    * `saved/2`        server accepted (new rev): if edits arrived meanwhile
                       the loop stays dirty and asks for another flush.
    * `conflicted/2`   CAS lost: caller merged the server's doc; base_rev jumps
                       to the server's rev; retry with backoff (bounded).
    * `failed/1`       network/rate-limit error: offline, retry with backoff.
    * `remote_merged/3` a visibility refetch merged a newer server doc.

  A dirty change is never dropped: running out of retries leaves `:failed`
  with `dirty?: true` (the UI says so and keeps offering a retry).
  """

  @max_retries 6
  @debounce_ms 1000
  @cap_ms 30_000

  def new(rev) when is_integer(rev) do
    %{
      status: :idle,
      base_rev: rev,
      seq: 0,
      flushed_seq: 0,
      inflight?: false,
      retries: 0,
      dirty?: false
    }
  end

  def debounce_ms, do: @debounce_ms
  def max_retries, do: @max_retries

  @doc "Backoff in ms after `n` consecutive failures: 500, 1000, 2000 ... cap 30 s."
  def backoff_ms(n) when n <= 1, do: 500
  def backoff_ms(n), do: min(500 * pow2(min(n - 1, 10)), @cap_ms)

  defp pow2(0), do: 1
  defp pow2(n), do: 2 * pow2(n - 1)

  def changed(s) do
    s = %{s | dirty?: true, seq: s.seq + 1, status: if(s.inflight?, do: :saving, else: :dirty)}
    {s, s.seq}
  end

  def flush_due?(s, token), do: s.dirty? and not s.inflight? and token == s.seq

  def flush_started(s), do: %{s | inflight?: true, flushed_seq: s.seq, status: :saving}

  @doc "`{state, :flush_again | :done}`."
  def saved(s, new_rev) do
    s = %{s | base_rev: new_rev, inflight?: false, retries: 0}

    if s.seq > s.flushed_seq,
      do: {%{s | status: :dirty}, :flush_again},
      else: {%{s | dirty?: false, status: :saved}, :done}
  end

  @doc "`{state, {:retry, delay_ms} | :give_up}`."
  def conflicted(s, remote_rev) do
    retry(%{s | base_rev: remote_rev, inflight?: false, dirty?: true}, :merged)
  end

  @doc "`{state, {:retry, delay_ms} | :give_up}` after a non-conflict failure."
  def failed(s), do: retry(%{s | inflight?: false, dirty?: true}, :offline)

  defp retry(s, status) do
    s = %{s | retries: s.retries + 1}

    if s.retries > @max_retries,
      do: {%{s | status: :failed}, :give_up},
      else: {%{s | status: status}, {:retry, backoff_ms(s.retries)}}
  end

  @doc """
  The server's copy could not be read (undecryptable or undecodable conflict
  reply). Nothing more can be done automatically: leave the in-flight state,
  keep the local doc dirty and stop at `:failed` so the user can retry (the
  retry saves again, which conflicts again and so re-fetches the server copy).
  """
  def stalled(s),
    do: %{s | inflight?: false, dirty?: s.dirty? or s.inflight?, retries: 0, status: :failed}

  @doc "Manual retry after `:failed`: resets the budget."
  def reset_retries(s), do: %{s | retries: 0, status: if(s.dirty?, do: :dirty, else: :idle)}

  @doc """
  A refetch merged a newer server revision into the local doc. `dirty?` says
  whether the merged doc differs from what the server has.
  """
  def remote_merged(s, remote_rev, dirty?) do
    s = %{s | base_rev: remote_rev, dirty?: s.dirty? or dirty?}
    s = if dirty?, do: %{s | seq: s.seq + 1}, else: s
    {%{s | status: if(s.dirty?, do: :dirty, else: :merged)}, s.seq}
  end

  @doc "Whether leaving the page would lose something (drives the beforeunload warning)."
  def unsaved?(s), do: s.dirty? or s.inflight?
end
