defmodule DebtReliefTracker.VaultDoc.Ledger do
  @moduledoc """
  Applies `DebtReliefTracker.Storage` changes to a `VaultDoc` -- the
  client-side replacement for `Storage.Plain` + the Ecto contexts, run by the
  browser on the decrypted document (and by ExUnit, which proves it matches
  the plaintext path step for step; `test/debt_relief_tracker/vault_doc/`).

  Pure and total: no clock, no randomness, no I/O, never raises on bad
  input. Everything the caller must supply is in `ctx`:

      %{
        now: "2026-11-01T12:00:00Z",   # any ISO UTC timestamp (normalised, see Stamp)
        today: "2026-11-01",           # the user's local date (due dates, interest estimate)
        new_id: fn -> "uuid" end,      # UUID source; called in the order below
        actor: nil | user_id,          # who is acting (activity user_id; nil = unattended)
        members: %{user_id => display_name}   # optional: confirmed workspace members
      }

  `members` is account data the vault does not hold. With it,
  `{:add_member_retirement_profile, user_id, _}` is `:not_found` for a
  non-member and records the member's display name; without it any user id is
  accepted and `display_name` is nil.

  ## API

    * `apply_change(doc, change, ctx)` -- `{:ok, doc} | {:error, :not_found |
      :not_due | {:invalid, %{atom => [String.t()]}}}`. Supports every change
      of the `Storage` moduledoc; an unknown change (or bad ctx) is
      `{:invalid, ...}`. On error the document is untouched (a change is
      all-or-nothing, which `Storage.Plain` only is per transaction).
    * `catch_up(doc, ctx)` -- `{:ok, doc, report}`, see below.

  ## Parity with `Storage.Plain`

  Validation errors have the same fields and messages (`Check`), and the same
  activity entries are appended (same action names, `user_id`, `debt_id`,
  `metadata` keys and string formats). Entry/record ids come from
  `ctx.new_id`, called in this order per change: the new record's id first,
  then one id per activity entry (`reconcile_balance`: payment, its
  activity, the debt-updated activity). Each activity entry gets its own
  strictly increasing timestamp (`now`, then +1 microsecond, ...), so
  "newest first" ordering matches insertion order exactly.

  Known divergences from the Decimal path (the parity tests pin the rest):

    * attrs that are not integers/ISO strings are `"is invalid"` (Plain
      raises on a missing/`nil` payment `amount`);
    * `reconcile_balance` works in whole cents: with an estimated-interest
      overlay Plain's payment keeps fractional cents (rounded when
      snapshotted, giving the same cent values) and its `payment_logged`
      metadata `"amount"` string carries those extra digits; here it has two
      decimals. A gap smaller than half a cent that Plain logs as a 0-cent
      payment is "no payment" here;
    * the document is edited atomically; Plain's reconcile can leave the
      payment saved if the following debt update fails.

  ## Timestamps and merging

  `updated_at` on debts/profiles is the last-writer-wins clock for
  `VaultDoc.Merge`: it is bumped by *deliberate* edits (add/update/mark paid
  off/delete, a reconcile's statement update) and kept strictly increasing per
  record. It is NOT bumped by changes whose effect `Merge` combines instead
  of overwriting: logging a payment (balance + `applied`) and
  `handle_due` / `catch_up` stamping `last_due_handled_on`. Editing a debt's
  balance directly (update_debt, reconcile without a payment) starts a new
  baseline: `applied` becomes "all payments the document has".

  ## Auto-posted payments and `catch_up`

  A `handle_due :post` (and every `catch_up` payment) uses
  `Engine.DueSchedule.payment_id(debt_id, cycle)` (`"<debt id>:<yyyy-mm-dd>"`)
  as the payment id and `"<payment id>:logged"` as its activity id; a skip
  uses `"<debt id>:<yyyy-mm-dd>:skipped"`. Two devices that catch up the same
  cycle therefore create the same records, which `Merge` dedupes. If the
  payment already exists the cycle is only stamped handled.

  `catch_up/2` posts, for every live debt with `auto_log_mode "automatic"`,
  each missed cycle oldest first (actor nil, activity `payment_auto_logged`),
  stopping a debt at the first cycle that cannot be posted (like the
  scheduler, e.g. a payment larger than the balance stays unposted). Debts in
  `"confirm"` mode are only reported. Idempotent. `report`:

      %{
        posted: [%{debt_id, cycle, payment_id}],
        stamped: [%{debt_id, cycle, payment_id}],   # payment already existed
        pending_confirm: [%{debt_id, cycles: [iso]}],
        failed: [%{debt_id, cycle, error}]
      }
  """

  alias DebtReliefTracker.Engine.{Calculations, Days, DueSchedule, FromSnapshot}
  alias DebtReliefTracker.VaultDoc
  alias DebtReliefTracker.VaultDoc.{Check, Stamp}

  @type ctx :: %{
          required(:now) => String.t(),
          required(:today) => String.t(),
          required(:new_id) => (-> String.t()),
          optional(:actor) => nil | String.t(),
          optional(:members) => %{String.t() => String.t()}
        }

  @bad_change {:error, {:invalid, %{change: ["is invalid"]}}}

  @spec apply_change(map(), DebtReliefTracker.Storage.change(), ctx()) ::
          {:ok, map()} | {:error, DebtReliefTracker.Storage.error()}
  def apply_change(doc, change, ctx) do
    with {:ok, st} <- init(doc, ctx),
         {:ok, st} <- run(st, change) do
      {:ok, st.doc}
    end
  rescue
    _ -> @bad_change
  end

  @spec catch_up(map(), ctx()) :: {:ok, map(), map()} | {:error, term()}
  def catch_up(doc, ctx) do
    with {:ok, st} <- init(doc, ctx) do
      st = %{st | actor: nil}
      empty = %{posted: [], stamped: [], pending_confirm: [], failed: []}

      {st, report} =
        st.doc.debts
        |> Map.values()
        |> Enum.reject(&(&1.deleted or &1.auto_log_mode == "off"))
        |> Enum.sort_by(& &1.id)
        |> Enum.reduce({st, empty}, fn debt, {st, report} -> catch_up_debt(st, debt, report) end)

      {:ok, st.doc,
       %{
         posted: Enum.reverse(report.posted),
         stamped: Enum.reverse(report.stamped),
         pending_confirm: Enum.reverse(report.pending_confirm),
         failed: Enum.reverse(report.failed)
       }}
    end
  rescue
    _ -> @bad_change
  end

  defp catch_up_debt(st, debt, report) do
    cycles = DueSchedule.missed_cycles(FromSnapshot.debt(debt), st.today)

    cond do
      cycles == [] ->
        {st, report}

      debt.auto_log_mode == "confirm" ->
        entry = %{debt_id: debt.id, cycles: Enum.map(cycles, &Stamp.format_date/1)}
        {st, %{report | pending_confirm: [entry | report.pending_confirm]}}

      true ->
        Enum.reduce_while(cycles, {st, report}, fn cycle, {st, report} ->
          rec = Map.fetch!(st.doc.debts, debt.id)
          iso = Stamp.format_date(cycle)
          info = %{debt_id: debt.id, cycle: iso, payment_id: DueSchedule.payment_id(debt.id, cycle)}

          case post_due(st, rec, cycle) do
            {:ok, st, :posted} -> {:cont, {st, %{report | posted: [info | report.posted]}}}
            {:ok, st, :stamped} -> {:cont, {st, %{report | stamped: [info | report.stamped]}}}
            {:error, error} ->
              failure = %{debt_id: debt.id, cycle: iso, error: error}
              {:halt, {st, %{report | failed: [failure | report.failed]}}}
          end
        end)
    end
  end

  # --- state -------------------------------------------------------------------

  defp init(doc, %{now: now, today: today, new_id: new_id} = ctx) when is_function(new_id, 0) do
    with {:ok, now} <- Stamp.normalize(now),
         {:ok, ymd} <- Stamp.parse_date(today),
         true <- is_map(doc) and doc.schema_version == VaultDoc.schema_version() do
      # New records must sort after everything already logged, even if the
      # device clock stands still or went backwards.
      latest = doc.activity |> Map.values() |> Enum.reduce(nil, &Stamp.max_stamp(&2, &1.inserted_at))
      clock = if latest != nil and now <= latest, do: Stamp.bump(latest), else: now

      {:ok,
       %{
         doc: doc,
         clock: clock,
         now: now,
         today: ymd,
         today_iso: Stamp.format_date(ymd),
         new_id: new_id,
         actor: Map.get(ctx, :actor),
         members: Map.get(ctx, :members)
       }}
    else
      _ -> {:error, {:invalid, %{ctx: ["is invalid"]}}}
    end
  end

  defp init(_doc, _ctx), do: {:error, {:invalid, %{ctx: ["is invalid"]}}}

  defp new_id(st), do: st.new_id.()

  # A fresh, strictly increasing stamp.
  defp tick(st), do: {st.clock, %{st | clock: Stamp.bump(st.clock)}}

  defp invalid({:ok, _} = ok), do: ok
  defp invalid({:error, errors}), do: {:error, {:invalid, errors}}

  defp live_debt(st, id) when is_binary(id) do
    case Map.get(st.doc.debts, id) do
      %{deleted: false} = rec -> {:ok, rec}
      _ -> {:error, :not_found}
    end
  end

  defp live_debt(_st, _id), do: {:error, :not_found}

  defp live_profile(st, id) when is_binary(id) do
    case Map.get(st.doc.retirement_profiles, id) do
      %{deleted: false} = rec -> {:ok, rec}
      _ -> {:error, :not_found}
    end
  end

  defp live_profile(_st, _id), do: {:error, :not_found}

  defp put(st, collection, rec),
    do: %{st | doc: Map.update!(st.doc, collection, &Map.put(&1, rec.id, rec))}

  defp activity(st, action, debt_id, user_id, metadata, id \\ nil) do
    id = id || new_id(st)

    if Map.has_key?(st.doc.activity, id) do
      st
    else
      {stamp, st} = tick(st)

      put(st, :activity, %{
        id: id,
        action: action,
        debt_id: debt_id,
        user_id: user_id,
        metadata: metadata,
        inserted_at: stamp,
        updated_at: stamp,
        deleted: false
      })
    end
  end

  # --- changes -----------------------------------------------------------------

  defp run(st, {:add_debt, attrs}) do
    with {:ok, values} <- invalid(Check.debt(Check.debt_defaults(), attrs)) do
      id = new_id(st)
      {stamp, st} = tick(st)

      rec =
        Map.merge(values, %{
          id: id,
          status: "active",
          paid_off_at: nil,
          updated_at: stamp,
          inserted_at: stamp,
          deleted: false,
          applied: %{}
        })

      {:ok, st |> put(:debts, rec) |> activity("debt_added", id, st.actor, %{"name" => rec.name})}
    end
  end

  defp run(st, {:update_debt, id, attrs}), do: update_debt(st, id, attrs)

  defp run(st, {:mark_paid_off, id}) do
    with {:ok, rec} <- live_debt(st, id) do
      {stamp, st} = tick(st)

      rec = %{
        rec
        | status: "paid_off",
          paid_off_at: Stamp.seconds(stamp),
          updated_at: Stamp.after_(stamp, rec.updated_at)
      }

      {:ok, st |> put(:debts, rec) |> activity("debt_paid_off", id, st.actor, %{"name" => rec.name})}
    end
  end

  defp run(st, {:delete_debt, id}) do
    with {:ok, rec} <- live_debt(st, id) do
      {stamp, st} = tick(st)
      st = put(st, :debts, %{rec | deleted: true, updated_at: Stamp.after_(stamp, rec.updated_at)})

      payments =
        Map.new(st.doc.payments, fn {pid, p} ->
          {pid, if(p.debt_id == id, do: %{p | deleted: true}, else: p)}
        end)

      st = %{st | doc: %{st.doc | payments: payments}}
      {:ok, activity(st, "debt_deleted", nil, st.actor, %{"name" => rec.name})}
    end
  end

  defp run(st, {:log_payment, debt_id, attrs}) do
    with {:ok, rec} <- live_debt(st, debt_id) do
      case post_payment(st, rec, attrs, action: "payment_logged", user: st.actor) do
        {:ok, st, _payment} -> {:ok, st}
        error -> error
      end
    end
  end

  defp run(st, {:update_settings, attrs}) do
    with {:ok, values} <- invalid(Check.settings(st.doc.settings, attrs)) do
      {stamp, st} = tick(st)

      {settings, stamps} =
        Enum.reduce(DebtReliefTracker.VaultDoc.Shape.settings_keys(), {st.doc.settings, st.doc.settings_updated_at}, fn
          key, {settings, stamps} ->
            if Map.fetch!(values, key) == Map.fetch!(settings, key) do
              {settings, stamps}
            else
              {Map.put(settings, key, Map.fetch!(values, key)),
               Map.put(stamps, key, Stamp.after_(stamp, Map.fetch!(stamps, key)))}
            end
        end)

      {:ok, %{st | doc: %{st.doc | settings: settings, settings_updated_at: stamps}}}
    end
  end

  defp run(st, {:reconcile_balance, id, new_balance}) when is_integer(new_balance) do
    with {:ok, rec} <- live_debt(st, id) do
      accrued =
        Calculations.accrued_interest_estimate(FromSnapshot.debt(rec), Days.to_days(st.today))

      implied = rec.balance + accrued - new_balance

      if implied > 0 do
        interest = min(accrued, implied)

        attrs = %{
          amount: implied,
          interest_portion: interest,
          principal_portion: implied - interest,
          paid_on: st.today_iso
        }

        with {:ok, st, _payment} <-
               post_payment(st, rec, attrs, action: "payment_logged", user: st.actor) do
          update_debt(st, id, %{statement_balance: new_balance, statement_date: st.today_iso})
        end
      else
        update_debt(st, id, %{
          balance: new_balance,
          statement_balance: new_balance,
          statement_date: st.today_iso
        })
      end
    end
  end

  defp run(st, {:handle_due, id, action, cycle_iso}) when action in [:post, :skip] do
    with {:ok, rec} <- live_debt(st, id),
         {:ok, cycle} <- due_cycle(st, rec, cycle_iso) do
      case action do
        :post ->
          with {:ok, st, _kind} <- post_due(st, rec, cycle), do: {:ok, st}

        :skip ->
          iso = Stamp.format_date(cycle)
          st = activity(st, "due_payment_skipped", id, st.actor, %{"cycle_due_date" => iso}, "#{id}:#{iso}:skipped")
          {:ok, put(st, :debts, %{rec | last_due_handled_on: iso})}
      end
    end
  end

  defp run(st, {:add_member_retirement_profile, user_id, attrs}) do
    with {:ok, display_name} <- member(st, user_id),
         {:ok, values} <- invalid(Check.profile(:member, Check.profile_defaults(), attrs)),
         :ok <- unique_member(st, user_id) do
      id = new_id(st)
      {stamp, st} = tick(st)

      rec =
        values
        |> Map.merge(%{
          id: id,
          user_id: user_id,
          display_name: display_name,
          name: nil,
          claim_email: nil,
          inserted_at: stamp,
          updated_at: stamp,
          deleted: false
        })

      {:ok, put(st, :retirement_profiles, rec)}
    end
  end

  defp run(st, {:add_manual_retirement_profile, attrs}) do
    with {:ok, values} <- invalid(Check.profile(:manual, Check.profile_defaults(), attrs)),
         :ok <- unique_email(st, values.claim_email, nil) do
      id = new_id(st)
      {stamp, st} = tick(st)

      rec =
        Map.merge(values, %{
          id: id,
          user_id: nil,
          display_name: values.name,
          inserted_at: stamp,
          updated_at: stamp,
          deleted: false
        })

      {:ok, put(st, :retirement_profiles, rec)}
    end
  end

  defp run(st, {:update_retirement_profile, id, attrs}) do
    with {:ok, rec} <- live_profile(st, id) do
      kind = if rec.user_id == nil, do: :update_manual, else: :update_linked

      with {:ok, values} <- invalid(Check.profile(kind, Check.profile_fields(rec), attrs)),
           :ok <- if(kind == :update_manual, do: unique_email(st, values.claim_email, id), else: :ok) do
        if values == Check.profile_fields(rec) do
          {:ok, st}
        else
          {stamp, st} = tick(st)
          new = Map.merge(rec, values)
          new = if kind == :update_manual, do: %{new | display_name: values.name}, else: new
          {:ok, put(st, :retirement_profiles, %{new | updated_at: Stamp.after_(stamp, rec.updated_at)})}
        end
      end
    end
  end

  defp run(st, {:delete_retirement_profile, id}) do
    with {:ok, rec} <- live_profile(st, id) do
      {stamp, st} = tick(st)
      {:ok, put(st, :retirement_profiles, %{rec | deleted: true, updated_at: Stamp.after_(stamp, rec.updated_at)})}
    end
  end

  defp run(_st, _change), do: @bad_change

  # --- debts -----------------------------------------------------------------

  defp update_debt(st, id, attrs) do
    with {:ok, rec} <- live_debt(st, id),
         {:ok, values} <- invalid(Check.debt(Check.debt_fields(rec), attrs)) do
      st =
        if values == Check.debt_fields(rec) do
          st
        else
          {stamp, st} = tick(st)
          new = Map.merge(rec, values)
          new = %{new | updated_at: Stamp.after_(stamp, rec.updated_at)}

          # A directly edited balance is a new baseline that already
          # accounts for every payment this document has.
          new =
            if values.balance == rec.balance,
              do: new,
              else: %{new | applied: debt_payments(st.doc, id)}

          put(st, :debts, new)
        end

      {:ok, activity(st, "debt_updated", id, st.actor, %{"name" => values.name})}
    end
  end

  # payment_id => principal, for the debt's payments in this document.
  defp debt_payments(doc, debt_id) do
    Map.new(
      for {pid, p} <- doc.payments, p.debt_id == debt_id and not p.deleted do
        {pid, VaultDoc.principal(p)}
      end
    )
  end

  # Logs a payment against `rec` (Payments.log_payment/5): `opts` has :action,
  # :user, and optionally :id and :activity_id (deterministic auto payments).
  defp post_payment(st, rec, attrs, opts) do
    with {:ok, p} <- invalid(Check.payment(attrs)) do
      principal = p.principal_portion || p.amount
      balance = rec.balance - principal

      if balance < 0 do
        {:error, {:invalid, %{balance: ["must be greater than or equal to 0"]}}}
      else
        id = Keyword.get(opts, :id) || new_id(st)
        {stamp, st} = tick(st)

        payment = %{
          id: id,
          debt_id: rec.id,
          amount: p.amount,
          principal_portion: principal,
          interest_portion: p.interest_portion,
          paid_on: p.paid_on,
          note: p.note,
          logged_by_user_id: nil,
          inserted_at: stamp,
          updated_at: stamp,
          deleted: false
        }

        rec = %{rec | balance: balance, applied: Map.put(rec.applied, id, principal)}

        st =
          st
          |> put(:payments, payment)
          |> put(:debts, rec)
          |> activity(
            Keyword.fetch!(opts, :action),
            rec.id,
            Keyword.fetch!(opts, :user),
            %{"amount" => cents_string(p.amount)},
            Keyword.get(opts, :activity_id)
          )

        {:ok, st, payment}
      end
    end
  end

  # --- due payments ----------------------------------------------------------

  # A cycle the debt really has due: a date on/before today that is one of its
  # due dates and not yet handled (DuePayments' own guards).
  defp due_cycle(st, rec, cycle_iso) do
    with {:ok, cycle} <- Stamp.parse_date(cycle_iso),
         true <- Days.to_days(cycle) <= Days.to_days(st.today),
         true <- is_integer(rec.due_day),
         ed = FromSnapshot.debt(rec),
         true <- DueSchedule.current_cycle_due_date(ed, cycle) == cycle,
         true <- DueSchedule.due?(ed, cycle) do
      {:ok, cycle}
    else
      _ -> {:error, :not_due}
    end
  end

  # Posts the fixed payment of `cycle` (deterministic ids) and stamps it
  # handled, or only stamps it if the payment already exists.
  defp post_due(st, rec, cycle) do
    iso = Stamp.format_date(cycle)
    pid = DueSchedule.payment_id(rec.id, cycle)

    case Map.get(st.doc.payments, pid) do
      %{deleted: false} ->
        {:ok, put(st, :debts, %{rec | last_due_handled_on: iso}), :stamped}

      _ ->
        action = if st.actor == nil, do: "payment_auto_logged", else: "payment_logged"

        with {:ok, st, _payment} <-
               post_payment(st, rec, %{amount: rec.fixed_payment, paid_on: iso},
                 action: action,
                 user: st.actor,
                 id: pid,
                 activity_id: pid <> ":logged"
               ) do
          rec = Map.fetch!(st.doc.debts, rec.id)
          {:ok, put(st, :debts, %{rec | last_due_handled_on: iso}), :posted}
        end
    end
  end

  # --- retirement profiles ---------------------------------------------------

  defp member(%{members: nil}, user_id) when is_binary(user_id), do: {:ok, nil}

  defp member(%{members: members}, user_id) when is_map(members) and is_binary(user_id) do
    case Map.fetch(members, user_id) do
      {:ok, name} -> {:ok, name}
      :error -> {:error, :not_found}
    end
  end

  defp member(_st, _user_id), do: {:error, :not_found}

  defp unique_member(st, user_id) do
    if Enum.any?(Map.values(st.doc.retirement_profiles), &(not &1.deleted and &1.user_id == user_id)),
      do: {:error, {:invalid, %{user_id: ["has already been taken"]}}},
      else: :ok
  end

  defp unique_email(_st, nil, _self), do: :ok

  defp unique_email(st, email, self) do
    taken =
      Enum.any?(
        Map.values(st.doc.retirement_profiles),
        &(not &1.deleted and &1.id != self and &1.claim_email == email)
      )

    if taken,
      do: {:error, {:invalid, %{claim_email: ["has already been taken"]}}},
      else: :ok
  end

  # --- formatting ------------------------------------------------------------

  @doc "Integer cents as the plain decimal string `Decimal.to_string/1` gives (`1050` -> `\"10.50\"`)."
  def cents_string(cents) when cents < 0, do: "-" <> cents_string(-cents)

  def cents_string(cents) do
    Integer.to_string(div(cents, 100)) <> "." <> String.pad_leading(Integer.to_string(rem(cents, 100)), 2, "0")
  end
end
