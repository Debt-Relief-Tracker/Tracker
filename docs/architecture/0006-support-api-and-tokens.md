# ADR 0006: Admin API (OpenAPISpex) + token auth

## Status

Accepted.

## Context

The owner wanted a way for an external system (e.g. an inbound-email
webhook or mail-forwarding rule) to log emails received at a support
address, visible from the existing admin interface, with access controlled
by tokens the admin manages themselves -- no shared secret baked into
config, no per-integration code changes to add or revoke access.

The router already had an unused `:api` pipeline and a commented-out
`/api` scope stub, clearly left as the intended place for this. No
token/API-key concept existed anywhere in the app before this.

## Decision

### `open_api_spex` for the API surface

Added as a new dependency rather than hand-rolling JSON responses, since
the owner explicitly wanted a Swagger/OpenAPI-documented interface.
`DebtReliefTrackerWeb.Api.Spec` builds the spec from the router
(`OpenApiSpex.Paths.from_router/1`); it's served as JSON at `/api/openapi`
and as an interactive UI at `/api/swaggerui`. Request/response shapes are
declared as `OpenApiSpex.Schema` modules
(`lib/debt_relief_tracker_web/api/schemas/`) and wired to the controller
action via `OpenApiSpex.ControllerSpecs`'s `operation/2` macro, so the docs
can't drift from the actual cast/validation behavior (`OpenApiSpex.Plug.
CastAndValidate` enforces the same schema at request time).

There's exactly one endpoint so far: `POST /api/support_emails`. No `GET`
was added -- "exposing them in the admin interface" is handled by
`AdminLive`'s new "Support Emails" tab, not by the API itself, keeping the
API surface minimal (write-only).

### Token design: hash-only storage, not Cloak encryption

`Accounts.ApiToken` stores only a SHA-256 hash of the raw token
(`token_hash`, unique-indexed for lookup) plus its last 4 characters
(`last_four`, plaintext, purely so an admin can tell tokens apart in the
list). The raw token itself (`"drt_" <> 32 random bytes, base64url`) is
generated once, returned to the admin exactly one time by `Accounts.
create_api_token/2`, and never persisted anywhere.

This is deliberately *not* the `Cloak`-based field encryption used
elsewhere (ADR 0005): encryption is reversible by design, which is the
wrong property for a credential the app never needs to read back, only
compare. A one-way hash is both simpler and strictly more defensive here --
a database leak alone can't be used to authenticate as a token, whereas a
leaked encryption key would let every encrypted column be read.

This also sidesteps the exact problem ADR 0005 explicitly declined to
solve for `retirement_profiles.claim_email` (an encrypted column needs a
separate blind-index/HMAC scheme to support equality lookups, since a
random-IV cipher makes `WHERE column = ?` impossible): a token's *entire
job* is exact-match lookup by the presented value, so plain deterministic
hashing is the correct tool, not a workaround.

Revocation is a soft delete (`revoked_at`), matching the app's existing
append-only/auditable style (`ActivityLog`, `SentEmail`) rather than
deleting the row outright -- an admin can still see a revoked token existed
and who created it.

### Scopes stored as JSON text, not `{:array, :string}`

Each token carries a `scopes` list (currently just `support_emails:write`,
enforced by `DebtReliefTrackerWeb.Plugs.ApiAuth`'s `scope:` plug option) so
future API endpoints can be gated independently without every existing
token automatically gaining access.

ADR 0001 (dual database adapter) requires migrations to avoid Postgres-only
types so the same migration file works on SQLite -- this rules out `{:array,
:string}`. `scopes` is instead stored as a single `:string` column holding
a JSON-encoded array, via a small custom type,
`DebtReliefTracker.Types.StringList` (`cast`/`load`/`dump` via
`Jason.encode!/decode!`). The Elixir-side value is a plain list of strings
throughout the schema/changeset/LiveView -- the JSON encoding is invisible
outside the type itself.

### `support_emails` field encryption

`subject`/`body`/`metadata` are Cloak-encrypted (`Encrypted.Binary`/
`Encrypted.Map`, ADR 0005's existing types), for the same reason as
`payments.note`: free text from a support request will very plausibly
restate the exact financial detail (balances, lender names) the app
otherwise protects. `metadata` is encrypted too, not just `body`/`subject`,
because ADR 0005 already found that a plaintext metadata column can
silently duplicate content encrypted elsewhere (the same mistake it
documents for `activity_logs.metadata`) -- and here `metadata` is
arbitrary caller-supplied JSON from an external system, so its contents
can't be assumed safe.

`from`/`to` stay plaintext, matching the existing `users.email`/
`workspace_invitations.email` precedent: they're routing/identity fields,
not the sensitive content being protected.

Both `api_tokens` and `support_emails` are brand-new tables (`CREATE TABLE`
only, no existing data touched), so -- unlike ADR 0005's three-stage
additive/backfill/drop migration for retrofitting encryption onto existing
columns -- a single migration per table was sufficient.

## Consequences

- A leaked `api_tokens` row reveals only a token's name, scopes, last-4,
  and hash -- never a usable credential.
- Adding a second API endpoint later just means adding its scope string to
  `ApiToken.known_scopes/0` and a new `ApiAuth`-gated pipeline; existing
  tokens keep whatever scopes they were issued with.
- `open_api_spex` is now a standing dependency; any future admin API
  endpoint should get an `operation/2` spec and a schema module rather than
  a bare, undocumented JSON action, to keep `/api/swaggerui` accurate.
