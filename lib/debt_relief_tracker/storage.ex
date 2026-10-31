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
  Conversion from the stored Decimals rounds to those units (cents; 0.01% for
  APR; 0.01% for minimum-payment rate), so a stored value with finer
  precision is rounded in the snapshot.

  ## Changes

    * `{:add_debt, attrs}` / `{:update_debt, id, attrs}` -- `attrs` use the
      snapshot's debt keys (`:balance`, `:apr_bp`, ...)
    * `{:delete_debt, id}` / `{:mark_paid_off, id}`
    * `{:log_payment, debt_id, attrs}` -- `:amount`, optional
      `:principal_portion`/`:interest_portion`, `:paid_on`, `:note`
    * `{:update_settings, attrs}`

  Every successful change returns the fresh snapshot.
  """

  alias DebtReliefTracker.Accounts.Workspace

  @type id :: String.t()
  @type snapshot :: %{
          schema_version: pos_integer(),
          settings: map(),
          debts: [map()],
          payments: [map()],
          activity: [map()]
        }
  @type change ::
          {:add_debt, map()}
          | {:update_debt, id(), map()}
          | {:delete_debt, id()}
          | {:mark_paid_off, id()}
          | {:log_payment, id(), map()}
          | {:update_settings, map()}
  @type error :: :not_found | {:invalid, %{atom() => [String.t()]}}

  @callback load(Workspace.t()) :: {:ok, snapshot()} | {:error, term()}
  @callback apply_change(Workspace.t(), user :: term(), change()) ::
              {:ok, snapshot()} | {:error, error()}

  @doc "The configured adapter (`Storage.Plain` unless overridden)."
  def adapter, do: Application.get_env(:debt_relief_tracker, :storage, __MODULE__.Plain)

  def load(workspace), do: adapter().load(workspace)
  def apply_change(workspace, user, change), do: adapter().apply_change(workspace, user, change)
end
