# ADR 0002: Auth and sharing model (Actual-Budget-style)

## Status

Accepted.

## Context

The app is primarily a personal, self-hosted tool: `minimum.md` describes a
single-user experience with no mention of accounts or login. At the same
time, it should be possible to share one set of debts/payments/plan with
another person (e.g. a partner) once the operator has an external identity
provider available — without requiring that capability to exist from day one,
and without a data-model migration to retrofit it later.

The reference point is [Actual Budget](https://actualbudget.org/): a single
shared "budget" (their unit of data) that has no login by default, but can be
put behind an external OIDC provider so multiple people can access the same
budget.

Important nuance: this is **not** "one global shared dataset with attribution
tags." Debts genuinely belong to a user (a `Workspace` the user owns), and
sharing is an explicit grant of access to another user's workspace — closer
to how a Google Doc is owned by one account and can be shared with others,
than to a single mutable global table everyone writes into.

## Decision

- **Ownership unit**: `Workspace` (think "budget file"). Every `Debt`,
  `Payment`, `Setting`, and `ActivityLog` entry belongs to a `Workspace`, not
  directly to a `User`.
- **`User`**: represents either the implicit default user (no-auth mode) or a
  real external OIDC identity (once OIDC is configured).
- **`WorkspaceMember`**: join table (`workspace_id`, `user_id`, `role`) — how
  an owner shares their workspace with another user. A user can own or belong
  to more than one workspace.
- **No-auth mode** (default; no `OIDC_*` env vars set): no login wall at all.
  A single implicit `User` and `Workspace` are seeded at boot, and every
  request resolves to that one workspace. Because there's exactly one
  workspace and one implicit member, none of the sharing/switcher UI has
  anything to show — it's invisible in this mode, not merely disabled.
- **OIDC mode** (`OIDC_ISSUER`, `OIDC_CLIENT_ID`, `OIDC_CLIENT_SECRET` set):
  use the [`assent`](https://hex.pm/packages/assent) library — a lightweight,
  framework-agnostic OAuth2/OIDC client with no opinion on user schema — to
  add a login redirect and a session plug guarding all routes. On first
  login, a `User` and their own new `Workspace` are created for that OIDC
  subject.
- **Sharing flow**: a workspace owner invites another known user (by
  email/subject match, or a shareable invite link/code) to become a
  `WorkspaceMember` on their workspace. That member then sees and can edit
  the same debts/payments as the owner. A workspace switcher only needs to
  appear in the UI once a user has membership in more than one workspace.
- **Attribution**: `Payment.logged_by_user_id` (nullable) and
  `ActivityLog.user_id` record *who* performed a shared action, purely for
  display ("logged by Alex") — they do not affect access control, which is
  entirely governed by `WorkspaceMember`.

## Consequences

- Every context function must take the workspace explicitly (e.g.
  `Debts.list_debts(workspace)`) from day one, even in no-auth mode where
  there's only ever one workspace — this is what avoids a schema migration
  when OIDC/sharing is turned on later.
- No-auth mode must not leak any workspace/sharing concepts into the UI; it
  should look and feel like a single-user app.
- We depend on an external OIDC provider for anything beyond the no-auth
  default — we do not build or maintain our own username/password auth
  system.

## Implementation notes

- `DebtReliefTrackerWeb.OIDC` wraps `Assent.Strategy.OIDC`; `enabled?/0` reads
  `Application.get_env(:debt_relief_tracker, :oidc)`, which `config/runtime.exs`
  sets (or sets to `nil`) from the three env vars. Every other OIDC-aware
  piece — `AuthController`, `DashboardLive` — checks `enabled?/0` rather than
  reading env vars itself.
- Routes (`/auth/login`, `/auth/callback`, `/auth/logout` in `AuthController`)
  always exist; they no-op back to `/` when OIDC isn't enabled, rather than
  being conditionally defined in the router. Simpler than trying to make the
  router itself conditional on a runtime value.
- `DashboardLive.mount/3` is the actual login gate: if OIDC is enabled and
  the plug session has no `user_id`, it redirects to `/auth/login` before
  rendering anything. There's no separate `:require_auth` plug in the
  browser pipeline — with only one route in the whole app, gating in
  `mount/3` is simpler and was preferred per earlier "keep it simple"
  feedback on this project.
- Sharing lives directly in `DashboardLive`'s header (a workspace `<select>`
  shown once `length(@workspaces) > 1`, and an email input shown only when
  `Accounts.owner?/2` is true for the currently-viewed workspace) rather than
  a separate settings page — there wasn't enough surface area here to justify
  one.
- Matches known users by email (`Accounts.share_workspace_with_email/3`) --
  "known" means they've logged in via OIDC at least once already, in which
  case they're granted access immediately and emailed a notice. If the email
  is unknown, a pending `WorkspaceInvitation` row is created instead and the
  address is emailed a plain sign-in link (via Resend/`Swoosh`,
  `Accounts.UserNotifier`) -- no separate shareable link/token is generated;
  the invitee just signs in normally at `/auth/login`, and
  `get_or_create_user_from_oidc!/1` fulfills any pending invitations for
  their email the moment their `User` is created, turning them into real
  `WorkspaceMember` access. The owner can see and cancel pending invitations
  from the same header UI.
- **Verification gap**: the actual browser → provider → callback → token
  exchange has not been run against a real OIDC provider (none available in
  the environment this was built in). Everything downstream of a session
  already carrying a `user_id` is covered by tests (see docs/roadmap.md
  Phase 7). Run one real login against your provider before depending on
  this in production.
