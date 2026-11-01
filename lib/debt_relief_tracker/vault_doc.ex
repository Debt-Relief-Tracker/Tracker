defmodule DebtReliefTracker.VaultDoc do
  @moduledoc """
  The decrypted contents of an E2EE vault (docs/architecture/0007-e2ee.md,
  "Vault document"): one versioned document that the browser edits with
  `VaultDoc.Ledger`, merges with `VaultDoc.Merge`, and encrypts as the JSON
  text of `encode/1`. Pure and client-safe (integer cents/basis points,
  ISO strings, no Decimal/Date/floats/Ecto); also run by ExUnit.

  (Named `VaultDoc` because `DebtReliefTracker.Vault` is the Cloak module.)

  ## Shape

      %{
        schema_version: 1,
        settings: %{monthly_budget, currency, budget_mode, retirement_onboarding_dismissed},
        settings_updated_at: %{monthly_budget: stamp, currency: stamp, ...},
        debts: %{id => debt_record},
        payments: %{id => payment_record},
        activity: %{id => activity_record},
        retirement_profiles: %{id => profile_record}
      }

  Collections are maps keyed by record id (O(1) lookups, a deterministic JSON
  object). Every record has a string `id` (a UUID, except auto-posted payments,
  see `Ledger`), `updated_at` and `deleted` (a tombstone, so merges can
  propagate deletes). Records carry the keys of the `Storage` snapshot
  (`docs/architecture/0007-e2ee.md`, `storage.ex`) in the same units, plus
  bookkeeping that `view/1` strips: `inserted_at` (debts), `deleted`,
  `updated_at` (all but debts' public `updated_at`, which `view/1` keeps
  because the snapshot has it), and for debts `applied`
  (`payment_id => principal applied to balance`, see `Merge`). Stamps are the
  canonical form of `VaultDoc.Stamp`.

  Settings merge per key: `settings_updated_at` holds one stamp per key, so a
  budget change on one device and a currency change on another both survive.

  ## Operations

    * `Ledger.apply_change/3`, `Ledger.catch_up/2` -- edit (the `Storage`
      change vocabulary)
    * `Merge.merge/2` -- reconcile two diverged copies
    * `view/1` -- a plain `Storage.snapshot` of the live records, for the UI
    * `from_snapshot/2` -- build a document from a `Storage.Plain` snapshot
      (the plaintext -> vault migration)
    * `encode/1` / `decode/1` -- deterministic JSON text (`VaultDoc.Json`)
  """

  alias DebtReliefTracker.VaultDoc.{Json, Shape, Stamp}

  @schema_version 1

  @debt_view [
    :id,
    :name,
    :type,
    :status,
    :balance,
    :original_balance,
    :apr_bp,
    :fixed_payment,
    :minimum_payment_floor,
    :minimum_payment_rate_bp,
    :credit_limit,
    :exclude_from_plan,
    :statement_balance,
    :statement_date,
    :position,
    :due_day,
    :auto_log_mode,
    :last_due_handled_on,
    :paid_off_at,
    :updated_at
  ]
  @payment_view [
    :id,
    :debt_id,
    :amount,
    :principal_portion,
    :interest_portion,
    :paid_on,
    :note,
    :logged_by_user_id,
    :inserted_at,
    :updated_at
  ]
  @activity_view [:id, :action, :debt_id, :user_id, :metadata, :inserted_at]
  @retirement_view [
    :id,
    :user_id,
    :display_name,
    :name,
    :claim_email,
    :current_age,
    :retirement_age,
    :current_retirement_savings,
    :monthly_retirement_contribution,
    :monthly_gross_income,
    :post_debt_investment_bp,
    :expected_annual_return_bp,
    :inserted_at,
    :updated_at
  ]

  def schema_version, do: @schema_version

  @doc "A document with default settings and no records."
  def new do
    %{
      schema_version: @schema_version,
      settings: %{
        monthly_budget: nil,
        currency: "USD",
        budget_mode: "total",
        retirement_onboarding_dismissed: false
      },
      settings_updated_at: Map.new(Shape.settings_keys(), &{&1, Stamp.epoch()}),
      debts: %{},
      payments: %{},
      activity: %{},
      retirement_profiles: %{}
    }
  end

  # --- view ------------------------------------------------------------------

  @doc """
  The live records as a `Storage.snapshot`, ordered exactly like
  `Storage.Snapshot.build/1`: debts by position, inserted_at, id; payments
  newest first (paid_on, inserted_at, id descending); activity newest first
  (inserted_at, id); retirement profiles oldest first. A payment is live iff
  it is not tombstoned and its debt is live; an activity entry whose debt was
  deleted shows `debt_id: nil` (the `ON DELETE SET NULL` of the plaintext
  path).
  """
  def view(doc) do
    # `for` instead of Enum.filter/reject: those are quadratic in the browser.
    debts = for d <- Map.values(doc.debts), not d.deleted, do: d
    live = Map.new(debts, &{&1.id, true})

    %{
      schema_version: doc.schema_version,
      settings: Map.put(doc.settings, :updated_at, doc.settings_updated_at |> Map.values() |> Enum.max()),
      debts:
        debts
        |> Enum.sort_by(&{&1.position, &1.inserted_at, &1.id})
        |> Enum.map(fn debt ->
          debt |> Map.take(@debt_view) |> Map.update!(:balance, &max(&1, 0))
        end),
      payments:
        for(p <- Map.values(doc.payments), not p.deleted and Map.has_key?(live, p.debt_id), do: p)
        |> Enum.sort_by(&{&1.paid_on, &1.inserted_at, &1.id})
        |> Enum.reverse()
        |> Enum.map(&Map.take(&1, @payment_view)),
      activity:
        for(e <- Map.values(doc.activity), not e.deleted, do: e)
        |> Enum.sort_by(&{&1.inserted_at, &1.id})
        |> Enum.reverse()
        |> Enum.map(fn entry ->
          entry = Map.take(entry, @activity_view)
          if Map.has_key?(live, entry.debt_id), do: entry, else: %{entry | debt_id: nil}
        end),
      retirement_profiles:
        for(r <- Map.values(doc.retirement_profiles), not r.deleted, do: r)
        |> Enum.sort_by(&{&1.inserted_at, &1.id})
        |> Enum.map(&Map.take(&1, @retirement_view))
    }
  end

  # --- from_snapshot -----------------------------------------------------------

  @doc """
  Builds a document from a `Storage.snapshot` (no tombstones). Missing or
  unparsable `updated_at` / `inserted_at` become `now` (default: the epoch).
  The snapshot's debts carry no `inserted_at`, so a debt's creation order is
  preserved by a synthetic `inserted_at` of
  `1970-01-01T00:00:00.00000<index>Z` following the snapshot's order (a debt
  map with its own `:inserted_at` keeps it); new debts, stamped with the real
  time, sort after. Each debt's `applied` set is every payment it has, since
  its balance already reflects them.
  """
  def from_snapshot(snapshot, now \\ nil) do
    now = Stamp.normalize_or_epoch(now)
    stamp = fn value -> Stamp.normalize(value) |> stamp_or(now) end

    payments =
      Map.new(snapshot.payments, fn p ->
        inserted = stamp.(p.inserted_at)

        {p.id,
         p
         |> Map.take(@payment_view)
         |> Map.merge(%{
           inserted_at: inserted,
           updated_at: stamp.(Map.get(p, :updated_at)) |> max(inserted),
           deleted: false
         })}
      end)

    payment_list = Map.values(payments)

    debts =
      snapshot.debts
      |> Enum.with_index()
      |> Map.new(fn {d, index} ->
        {d.id,
         d
         |> Map.take(@debt_view)
         |> Map.merge(%{
           updated_at: stamp.(Map.get(d, :updated_at)),
           inserted_at: inserted_or_synthetic(Map.get(d, :inserted_at), index),
           deleted: false,
           applied: Map.new(for(p <- payment_list, p.debt_id == d.id, do: {p.id, principal(p)}))
         })}
      end)

    %{
      schema_version: @schema_version,
      settings: Map.take(snapshot.settings, Shape.settings_keys()),
      settings_updated_at:
        Map.new(Shape.settings_keys(), &{&1, stamp.(Map.get(snapshot.settings, :updated_at))}),
      debts: debts,
      payments: payments,
      activity:
        Map.new(snapshot.activity, fn e ->
          inserted = stamp.(e.inserted_at)

          {e.id,
           e
           |> Map.take(@activity_view)
           |> Map.merge(%{inserted_at: inserted, updated_at: inserted, deleted: false})}
        end),
      retirement_profiles:
        Map.new(snapshot.retirement_profiles, fn r ->
          inserted = stamp.(Map.get(r, :inserted_at))

          {r.id,
           r
           |> Map.take(@retirement_view)
           |> Map.merge(%{
             inserted_at: inserted,
             updated_at: stamp.(Map.get(r, :updated_at)) |> max(inserted),
             deleted: false
           })}
        end)
    }
  end

  @doc "The principal a payment takes off its debt's balance (a legacy nil split counts as 0)."
  def principal(payment), do: Map.get(payment, :principal_portion) || 0

  defp stamp_or({:ok, stamp}, _now), do: stamp
  defp stamp_or(:error, now), do: now

  defp inserted_or_synthetic(value, index) do
    case Stamp.normalize(value) do
      {:ok, stamp} -> stamp
      :error -> "1970-01-01T00:00:00." <> String.pad_leading(Integer.to_string(index), 6, "0") <> "Z"
    end
  end

  # --- serialisation ------------------------------------------------------------

  @doc "Deterministic JSON text of the document (the plaintext the facade encrypts)."
  @spec encode(map()) :: String.t()
  def encode(doc), do: Json.encode(doc)

  @doc """
  Parses `encode/1` output. `{:error, :invalid}` for anything malformed,
  oversized, of an unknown `schema_version`, or with a record that does not
  match the field tables (`VaultDoc.Shape`); unknown keys are dropped.
  """
  @spec decode(term()) :: {:ok, map()} | {:error, :invalid}
  def decode(text) do
    with {:ok, %{"schema_version" => @schema_version} = raw} <- Json.decode(text),
         {:ok, settings, stamps} <-
           Shape.settings(Map.get(raw, "settings"), Map.get(raw, "settings_updated_at")),
         {:ok, debts} <- Shape.records(:debt, Map.get(raw, "debts")),
         {:ok, payments} <- Shape.records(:payment, Map.get(raw, "payments")),
         {:ok, activity} <- Shape.records(:activity, Map.get(raw, "activity")),
         {:ok, profiles} <- Shape.records(:retirement, Map.get(raw, "retirement_profiles")) do
      {:ok,
       %{
         schema_version: @schema_version,
         settings: settings,
         settings_updated_at: stamps,
         debts: debts,
         payments: payments,
         activity: activity,
         retirement_profiles: profiles
       }}
    else
      _ -> {:error, :invalid}
    end
  end
end
