defmodule DebtReliefTracker.VaultDoc.Merge do
  @moduledoc """
  Reconciles two diverged copies of a vault document (the client's `rev`
  compare-and-swap lost and it must re-apply onto the server's newer copy).
  `merge(a, b)` is **commutative, associative and idempotent** (property
  tested), so any number of devices converge no matter who merges with whom,
  in what order, or how often. Pure and client-safe.

  ## Per collection

    * **activity** and **payments** are append-only: union by `id`. If both
      sides have the same id (deterministic auto payments) the copy with the
      smaller `{inserted_at, JSON}` is kept.
    * A **payment is deleted iff its debt is deleted**: after debts are
      merged, every payment takes its debt's tombstone flag (a payment whose
      debt is unknown keeps the OR of the flags). So a tombstone beats a live
      copy, and if a debt is resurrected (below) its payments come back with
      it.
    * **debts** and **retirement profiles**: per record last-writer-wins on
      `updated_at` (canonical fixed-width stamps, compared as strings). On
      equal stamps a tombstone beats a live record -- "a newer edit of a
      deleted record wins only if strictly newer than the tombstone" -- and
      remaining ties go to the greater canonical JSON of the record's
      *deliberate* content (see below), so the choice is the same from both
      sides.
    * **settings**: per key, last-writer-wins on `settings_updated_at[key]`
      (ties: the greater JSON of the value).

  ## Concurrent payments (the dangerous case)

  Balances are user-entered baselines and are never recomputed from
  payments, but logging a payment on two devices at once must lower the
  balance by *both* payments, while per-record LWW would keep only one
  device's record. The design:

    * A debt record carries `applied`: `%{payment_id => principal}`, exactly
      the payments (and the amounts) that are already reflected in its
      `balance`. `Ledger` adds an entry whenever it logs a payment and resets
      `applied` to "all payments in the document" whenever the balance is
      edited directly (a new baseline).
    * Logging a payment does not bump the debt's `updated_at`, so it never
      competes with a concurrent rename/edit in the LWW race.
    * When two copies of a debt merge, the LWW winner `w` is taken as the
      baseline and every payment of the debt in the union that `w` has not
      applied (or applied with a different principal) is applied:

          balance = w.balance - sum(principal(p) - w.applied[p])   for p in union
          applied = principal(p) for every p in the union

      Each payment is thereby applied exactly once, whichever device logged
      it and in whatever order merges happen. Formally `gross = balance +
      sum(applied)` is invariant under merging, the winner is a function of
      the *deliberate* content only (everything except `balance`, `applied`
      and `last_due_handled_on`, plus `gross`), and the merged balance is
      `gross(winner) - sum(principal over the union of payments)`, which does
      not depend on merge order.
    * `last_due_handled_on` is merged as the maximum of both sides (stamping a
      handled cycle is monotone and, like payments, must not lose to a
      concurrent edit); lowering it by hand is not preserved across a merge.
    * The result can in principle be below zero (two devices both pay off the
      same debt); the document keeps the exact value (so merging stays
      associative) and `VaultDoc.view/1` clamps the displayed balance at 0.

  Two devices that both post the same cycle's auto payment use the same
  payment id (`Engine.DueSchedule.payment_id/2`), so the union has one
  payment and it is applied once.
  """

  alias DebtReliefTracker.VaultDoc
  alias DebtReliefTracker.VaultDoc.{Json, Shape}

  @spec merge(map(), map()) :: map()
  def merge(a, b) do
    {settings, stamps} = merge_settings(a, b)

    debts = merge_records(a.debts, b.debts, &debt_content/1)
    payments = union(a.payments, b.payments, &pick_append_only/2)

    payments =
      Map.new(payments, fn {id, p} ->
        case Map.get(debts, p.debt_id) do
          nil -> {id, p}
          debt -> {id, %{p | deleted: debt.deleted}}
        end
      end)

    %{
      schema_version: a.schema_version,
      settings: settings,
      settings_updated_at: stamps,
      debts: apply_payments(debts, payments),
      payments: payments,
      activity: union(a.activity, b.activity, &pick_append_only/2),
      retirement_profiles: merge_records(a.retirement_profiles, b.retirement_profiles, &Json.encode/1)
    }
  end

  # --- settings ----------------------------------------------------------------

  defp merge_settings(a, b) do
    Enum.reduce(Shape.settings_keys(), {%{}, %{}}, fn key, {settings, stamps} ->
      sa = Map.fetch!(a.settings_updated_at, key)
      sb = Map.fetch!(b.settings_updated_at, key)
      va = Map.fetch!(a.settings, key)
      vb = Map.fetch!(b.settings, key)

      value =
        cond do
          sa > sb -> va
          sa < sb -> vb
          Json.encode(va) >= Json.encode(vb) -> va
          true -> vb
        end

      {Map.put(settings, key, value), Map.put(stamps, key, max(sa, sb))}
    end)
  end

  # --- generic -----------------------------------------------------------------

  # Map.merge/3 is a native, linear operation in the browser (a reduce with
  # Map.put is quadratic).
  defp union(x, y, pick), do: Map.merge(x, y, fn _id, mine, theirs -> pick.(mine, theirs) end)

  defp pick_append_only(x, y) do
    cond do
      x == y -> x
      {x.inserted_at, Json.encode(x)} <= {y.inserted_at, Json.encode(y)} -> %{x | deleted: x.deleted or y.deleted}
      true -> %{y | deleted: x.deleted or y.deleted}
    end
  end

  # Per-record LWW over debts / profiles. `content` is the tie-break text.
  defp merge_records(x, y, content) do
    union(x, y, fn mine, theirs ->
      winner = winner(mine, theirs, content)

      if Map.has_key?(winner, :last_due_handled_on),
        do: %{winner | last_due_handled_on: max_date(mine.last_due_handled_on, theirs.last_due_handled_on)},
        else: winner
    end)
  end

  defp winner(x, y, content) do
    cond do
      x.updated_at > y.updated_at -> x
      x.updated_at < y.updated_at -> y
      x.deleted != y.deleted -> if(x.deleted, do: x, else: y)
      content.(x) >= content.(y) -> x
      true -> y
    end
  end

  defp max_date(nil, b), do: b
  defp max_date(a, nil), do: a
  defp max_date(a, b), do: if(a >= b, do: a, else: b)

  # --- debts -------------------------------------------------------------------

  defp gross(debt), do: debt.balance + Enum.reduce(debt.applied, 0, fn {_id, n}, acc -> acc + n end)

  # Deliberate content: what a user edit decides (not payment-derived state).
  defp debt_content(debt) do
    debt
    |> Map.drop([:balance, :applied, :last_due_handled_on])
    |> Map.put(:gross, gross(debt))
    |> Json.encode()
  end

  # Applies, to each live debt, every live payment its `applied` set lacks.
  defp apply_payments(debts, payments) do
    live_payments = for p <- Map.values(payments), not p.deleted, do: p

    Map.new(debts, fn {id, debt} ->
      list = if debt.deleted, do: [], else: for(p <- live_payments, p.debt_id == id, do: p)

      if list == [] do
        {id, debt}
      else
        # balance -= sum(principal - what the winner already applied)
        delta =
          Enum.reduce(list, 0, fn p, acc ->
            acc + VaultDoc.principal(p) - Map.get(debt.applied, p.id, 0)
          end)

        applied = Map.merge(debt.applied, Map.new(list, &{&1.id, VaultDoc.principal(&1)}))
        {id, %{debt | balance: debt.balance - delta, applied: applied}}
      end
    end)
  end
end
