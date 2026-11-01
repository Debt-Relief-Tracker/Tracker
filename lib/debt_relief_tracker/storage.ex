defmodule DebtReliefTracker.Storage do
  @moduledoc """
  Where a workspace's data lives (docs/architecture/0007-e2ee.md). The UI and
  engine only ever see a `t:snapshot/0` -- plain, JSON-clean data in the
  integer engine's units -- and change it through `t:change/0` tuples, so
  they cannot tell which adapter is active:

    * `Storage.Plain` -- today's tables, written through the existing
      `Debts`/`Payments`/`Settings` contexts (validation and activity
      logging stay in one place).
    * `Storage.Vault` (E2EE, not built yet) -- ciphertext only. The browser
      holds the decrypted snapshot, applies the same changes locally and
      uploads the re-encrypted document; the server never calls
      `apply_change/3` for it.

  ## Snapshot

  Money is integer cents, rates are basis points (`apr_bp`,
  `minimum_payment_rate_bp`), dates are ISO 8601 strings, enums are strings.
  `settings`, `debts`, `payments` and `retirement_profiles` rows carry
  `updated_at` (ISO 8601 UTC; `settings` and `retirement_profiles` are stored
  as naive timestamps so theirs has no `Z`, like their `inserted_at`) so a future sync can tell which copy
  of a row is newer; `activity` rows are append-only and carry only
  `inserted_at`. These are additive: no key was renamed or removed and
  `schema_version` stays `1`.

  Conversion from the stored Decimals rounds to those units (cents; 0.01% for
  APR; 0.01% for minimum-payment rate), so a stored value with finer
  precision is rounded in the snapshot. `mix drt.audit_snapshot` lists every
  stored value that would be (docs/architecture/0007-e2ee.md).

  ## Changes

    * `{:add_debt, attrs}` / `{:update_debt, id, attrs}` -- `attrs` use the
      snapshot's debt keys (`:balance`, `:apr_bp`, ...)
    * `{:delete_debt, id}` / `{:mark_paid_off, id}`
    * `{:log_payment, debt_id, attrs}` -- `:amount`, optional
      `:principal_portion`/`:interest_portion`, `:paid_on`, `:note`
    * `{:update_settings, attrs}` -- also how the retirement onboarding
      prompt is dismissed: `%{retirement_onboarding_dismissed: true}`
    * `{:reconcile_balance, debt_id, new_balance_cents}` -- the "log all
      balances" flow (`Debts.reconcile_balance/5`): logs the gap to the
      estimated balance as a payment and resets the statement baseline
    * `{:handle_due, debt_id, :post | :skip, cycle_due_date_iso}` -- confirm-mode
      due payments (`DuePayments`): `:post` logs the fixed payment (activity
      `payment_auto_logged`, or `payment_logged` for a signed-in user) and
      stamps `last_due_handled_on`; `:skip` only stamps it (activity
      `due_payment_skipped`). `{:error, :not_due}` if that cycle is not
      actually due.
    * `{:add_member_retirement_profile, user_id, attrs}` -- a profile for a
      confirmed workspace member (owner or invited member); `:not_found` for
      anyone else
    * `{:add_manual_retirement_profile, attrs}` -- a profile for someone with
      no account: `:name` and optional `:claim_email`
    * `{:update_retirement_profile, id, attrs}` / `{:delete_retirement_profile, id}`

  Retirement profile `attrs` use the snapshot's `retirement_profiles` keys:
  `:current_age`, `:retirement_age`, `:current_retirement_savings`,
  `:monthly_retirement_contribution`, `:monthly_gross_income` (cents),
  `:post_debt_investment_bp`, `:expected_annual_return_bp` (basis points of a
  percent: 15% -> `1500`), plus `:name`/`:claim_email` for manual profiles.
  Editing a member-linked profile ignores `:name`/`:claim_email`, as the
  LiveView does.

  The snapshot's `retirement_profiles` list (oldest first) carries each
  person's inputs in those same units, plus `:user_id` (nil for a manual
  profile) and a resolved `:display_name`. Who the *eligible* members for a new
  profile are is account data, not part of the snapshot -- see
  `DebtReliefTrackerWeb.Holo.Components.RetirementModal`.

  Every successful change returns the fresh snapshot.
  """

  alias DebtReliefTracker.Accounts.Workspace

  @type id :: String.t()
  @type snapshot :: %{
          schema_version: pos_integer(),
          settings: map(),
          debts: [map()],
          payments: [map()],
          activity: [map()],
          retirement_profiles: [map()]
        }
  @type change ::
          {:add_debt, map()}
          | {:update_debt, id(), map()}
          | {:delete_debt, id()}
          | {:mark_paid_off, id()}
          | {:log_payment, id(), map()}
          | {:update_settings, map()}
          | {:add_member_retirement_profile, id(), map()}
          | {:add_manual_retirement_profile, map()}
          | {:update_retirement_profile, id(), map()}
          | {:delete_retirement_profile, id()}
          | {:reconcile_balance, id(), integer()}
          | {:handle_due, id(), :post | :skip, String.t()}
  @type error :: :not_found | :not_due | {:invalid, %{atom() => [String.t()]}}

  @callback load(Workspace.t()) :: {:ok, snapshot()} | {:error, term()}
  @callback apply_change(Workspace.t(), user :: term(), change()) ::
              {:ok, snapshot()} | {:error, error()}

  @doc "The configured adapter (`Storage.Plain` unless overridden)."
  def adapter, do: Application.get_env(:debt_relief_tracker, :storage, __MODULE__.Plain)

  def load(workspace), do: adapter().load(workspace)
  def apply_change(workspace, user, change), do: adapter().apply_change(workspace, user, change)
end
