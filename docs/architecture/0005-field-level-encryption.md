# ADR 0005: UUID primary keys + field-level encryption

## Status

Accepted.

## Context

The app holds real personal financial data (loans, payments, retirement
info) for its two users, with no staging environment. The owner asked to
reduce what someone with raw database access (a DB dump, hosting-provider
access, a leaked backup) could learn about a specific user's debts, without
adding any user-facing unlock/transcode step.

Two independent gaps existed:

1. Every table used a sequential integer primary key, making rows trivially
   enumerable/correlatable, and leaking incidental information (row counts,
   relative creation order) to anyone with raw table access.
2. The actual sensitive figures (balances, APRs, payment amounts, debt/
   lender names, retirement figures) sat in plaintext. A UUID id change
   alone does not address this -- it only makes rows harder to enumerate,
   not their content unreadable.

## Decision

### UUID primary keys

Every table's primary key was converted from an integer auto-increment to
a UUID (`:binary_id`), via a full table rebuild
(`priv/repo/migrations/20260920120000_convert_primary_keys_to_uuid.exs` +
`..._drop_legacy_id_columns.exs`) rather than an additive `public_id`
column -- the owner chose the more invasive option explicitly, accepting
the larger one-time migration risk over leaving an internal integer PK in
place.

Notable fallout fixed as part of this: `debts.ex`/`payments.ex`'s
`order_by` clauses used `id` as an insertion-order tiebreak, which a random
UUID no longer approximates -- `inserted_at` was added ahead of `id` in
both, and (discovered via test failures, not by inspection)
`ActivityLog.Entry`/`Debt`/`Payment`'s `timestamps()` were upgraded to
`:utc_datetime_usec` so same-second ties actually resolve by real
insertion order instead of falling through to a random UUID. `sent_emails.
metadata`'s embedded integer ids (read by `Accounts.resend_email/1`) were
remapped to their new UUIDs by the migration, and `resend_email/1` was
hardened to degrade to `{:error, :gone}` on any uncastable id rather than
raising.

### Field-level encryption

Added [`cloak`](https://hexdocs.pm/cloak) + [`cloak_ecto`](https://hexdocs.pm/cloak_ecto)
(AES-GCM, random IV per value) rather than hand-rolling encryption --
`cloak_ecto` ships ready-made `Ecto.Type`s for every primitive this app
needs (`Cloak.Ecto.Binary`, `Cloak.Ecto.Decimal`, `Cloak.Ecto.Integer`,
`Cloak.Ecto.Map`), so `lib/debt_relief_tracker/encrypted/*.ex` are thin
wrappers, and the change to each schema is a field-type swap with no
changeset/LiveView/template changes anywhere.

`DebtReliefTracker.Vault` is keyed by `ENCRYPTION_KEY` (prod, required,
raises at boot if missing -- see `config/runtime.exs`) or a fixed dummy key
checked into `config/dev.exs`/`config/test.exs`, following the exact
pattern already used for `SECRET_KEY_BASE`.

**Encrypted:** `debts.{name,balance,original_balance,apr,
minimum_payment_floor,minimum_payment_rate,fixed_payment,credit_limit,
statement_balance}`; `payments.{amount,principal_portion,interest_portion,
note}`; `retirement_profiles.{name,current_age,retirement_age,
current_retirement_savings,monthly_retirement_contribution,
monthly_gross_income,post_debt_investment_pct,expected_annual_return_pct}`;
`settings.monthly_budget`; `activity_logs.metadata`.

The last one is not obvious and was easy to miss: `activity_logs.metadata`
embeds plaintext copies of exactly the data being encrypted elsewhere
(`%{"name" => debt.name}` on every debt add/update/paid-off/delete,
`%{"amount" => ...}` on every logged payment). Encrypting `debts.name`/
`payments.amount` while leaving this table alone would have defeated most
of the point.

**Deliberately left plaintext:**

- `debts.position`/`payments.paid_on` -- active `ORDER BY` keys; encrypting
  breaks ordering.
- `retirement_profiles.claim_email` -- carries a partial unique DB index
  and a plaintext `WHERE`-equality lookup
  (`Settings.claim_retirement_profiles/1`, which runs on every OIDC login);
  a random-IV cipher breaks both silently. The same email already sits in
  plaintext in `users.email`/`workspace_invitations.email`, so encrypting
  only this one copy would be security theater, not real protection, for
  the stated goal of protecting financial figures rather than identity. A
  blind-index design (a separate `claim_email_hash` column + `Cloak.Ecto.
  HMAC`) was considered and rejected: it adds a new column, four
  changesets to keep in sync, and a rewritten query, for zero protection of
  actual debt data.
- `users.email`/`workspace_invitations.email` -- same reasoning.
  `users.external_subject` (the real OIDC login key) and `users.
  display_name` also stay plaintext.
- Everything else (enums, booleans, operational dates) -- low sensitivity,
  no benefit.

### Migration shape: additive, then drop, run together

Three migrations, run back to back in one sitting (rather than staged
across separate deploys, per the owner's explicit low-stakes/two-user
risk call):

1. `add_encrypted_columns.exs` -- pure `alter table ... add ..._enc,
   :binary`, fully reversible, no data touched.
2. `backfill_encrypted_columns.exs` -- reads every plaintext value via raw
   SQL, encrypts it, writes the `_enc` column, and immediately decrypts it
   back to verify the round-trip inline (raising, and rolling back the
   whole transaction, on any mismatch). `down/0` NULLs the `_enc` columns
   -- a real, correct rollback, since the plaintext columns are untouched.
3. `drop_plaintext_columns.exs` -- the one genuinely irreversible step,
   kept in its own small file for the same reason
   `drop_legacy_id_columns.exs` is: easy to review in isolation.

Two adapter-specific details worth recording, both found empirically
rather than by inspection:

- SQLite's `:decimal` columns have NUMERIC affinity, so a raw SQL read
  returns a native float/integer, not an exact decimal string. The
  backfill reproduces `Ecto.Adapters.SQLite3.Codec.decimal_decode/1`'s
  exact logic (`is_float -> Decimal.from_float/1`, `is_binary or
  is_integer -> Decimal.new/1`) so it produces the identical value the app
  already computes when loading these columns through Ecto today -- not a
  new source of precision loss. Postgres has no such issue: postgrex
  always decodes `NUMERIC` to `%Decimal{}` directly, even via a raw query.
- Ciphertext must be bound as a query parameter, not inlined as a SQL
  literal (unlike the UUID migration's safe integer/UUID literals --
  arbitrary encrypted bytes can contain quote characters or invalid
  encoding). On SQLite it must be wrapped as `{:blob, binary}` so exqlite
  binds it as an actual BLOB; verified with a hex dump
  (`hex(substr(col,1,13))` shows the `<<1,10,"AES.GCM.V1">>` tag, and
  `typeof(col)` reports `blob`, not `text`).

A related, previously-undocumented SQLite storage quirk surfaced as a
consequence of moving decimal columns to opaque binary storage: SQLite's
NUMERIC affinity silently coerced a whole-number-valued decimal like
"1000.00" into an `INTEGER` storage class, discarding the trailing zeros
on read (`CSVExport` would show "1000" instead of "1000.00"). Encrypted
columns bypass this entirely and preserve the exact precision entered --
an improvement, not a regression, but it changed two `CSVExport` test
fixtures' expected output.

## Consequences

- **Key loss is permanent and total.** After the drop-plaintext migration
  runs, `ENCRYPTION_KEY` is the only way to read any encrypted column, for
  any row, ever. Database backups do not help -- they contain the same
  ciphertext. The key must be backed up in a password manager plus one
  offline copy, stored separately from where database backups live.
- No query rewrites were needed anywhere: confirmed via a full grep of
  `lib/` that no `Repo.aggregate`/`sum`/`WHERE`/`ORDER BY` touches any of
  the encrypted columns -- all totals are already computed in Elixir after
  loading records.
- `claim_email`/`users.email`/`workspace_invitations.email` remain a
  plaintext identity trail linking a workspace to a person, even though
  its financial contents are now unreadable without the key. Accepted as
  the correct scope boundary for this change -- see the rejected
  blind-index design above if this is ever revisited.
- A raw `sqlite3`/`psql` inspection of `debts`, `payments`,
  `retirement_profiles`, `settings`, and `activity_logs` now shows only
  ids, structural FKs, enums/booleans/dates, and opaque ciphertext blobs --
  no financial figures or names.
