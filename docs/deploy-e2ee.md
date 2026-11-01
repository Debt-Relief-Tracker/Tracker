# E2EE two-step deploy runbook (Render)

Background: `docs/architecture/0007-e2ee.md` ("Production rollout"). Step 2 is
**irreversible**: there is no path from E2EE back to plaintext.

## Step 0 - prechecks (before step 1)

- [ ] `mix test` green (SQLite) and `scripts/pg_test.sh` green (Postgres is the
      production path).
- [ ] Take a Render Postgres backup: Dashboard -> your Postgres -> Backups ->
      "Create backup" (or `pg_dump "$EXTERNAL_DATABASE_URL" -Fc -f pre-e2ee.dump`).
      Keep it until you are sure; note it holds plaintext (encrypted only by the
      Cloak `ENCRYPTION_KEY`).
- [ ] Restore that dump into a scratch Postgres (never prod) and run the audit
      against the COPY, with prod's Cloak key:
      `DATABASE_URL=ecto://... DATABASE_USE_SSL=false ENCRYPTION_KEY=<prod key> mix drt.audit_snapshot`
      Read-only; exit 0 = no precision loss, exit 1 = lists values the E2EE
      integer snapshot would round (review each before step 2).
- [ ] `ENCRYPTION_KEY` is stored in your password manager (losing it destroys data).

## Step 1 - deploy with `E2EE` unset

- [ ] Make sure `E2EE` is NOT set in Render's environment, deploy.
- [ ] Migrations that run at boot (Ecto.Migrator in the supervision tree):
      only `20261031120000_create_e2ee_vaults` - creates two NEW empty tables
      `e2ee_vaults` and `e2ee_key_wraps`. Additive; no existing table touched.
- [ ] Verify: log in, `/` (LiveView) works, `/app` loads in plaintext mode,
      `/export/debts.csv` downloads, boot log shows no `[error]`.
- [ ] Rollback = redeploy the previous image. The two new tables are unused by
      the old code, so no schema rollback is needed.

## Step 2 - set `E2EE=true`

- [ ] Re-check the backup from step 0 is recent; take another.
- [ ] Render -> Environment -> add `E2EE=true` (accepted: `true`, `1`, `yes`) and
      redeploy.
- [ ] Boot checks (the app refuses to start / logs the reason):
  - E2EE on, OIDC off, `PHX_HOST` not localhost -> refuses (OIDC required on
    public hosts). Keep `OIDC_*` set.
  - Vaults exist but `E2EE` off -> refuses to start ("never show an empty app").
    So never remove the variable once users have migrated.
- [ ] What users see: after the next login a forced setup wizard (passphrase /
      passkey / recovery key), then their plaintext is moved into a vault.
      Owners of shared workspaces see who will lose access and must confirm;
      other members lose that workspace (keep their own).
      `/` redirects (302) and `/export/debts.csv` returns 410 (data is
      client-side; use the in-app CSV download).
- [ ] Watch the admin page's "unmigrated workspaces" count fall. Users who never
      return stay plaintext (still Cloak-encrypted) until they log in; no
      automatic deletion.
- [ ] User stuck: if they still have any unlock method, have them retry on
      another device. If they lost every method, the app offers "start over",
      which wipes the vault; their data is unrecoverable by design.
- [ ] No way back to plaintext. Old Render backups keep pre-migration plaintext
      until they age out.

## Environment variables

| Variable | Required | Notes |
|---|---|---|
| `E2EE` | no (**new**) | `true`/`1`/`yes` enables E2EE. Step 2 only. |
| `PHX_HOST` | yes (required in prod) | public hostname; also decides the localhost exemption for E2EE-without-OIDC. Unset in a prod release counts as PUBLIC, so E2EE without OIDC refuses to boot |
| `FORCE_SSL` | no (**set `true` on Render**) | `true`/`1`/`yes`: redirect HTTP to HTTPS (honours `x-forwarded-proto`, as Render terminates TLS), send HSTS and mark cookies (incl. the session cookie) `Secure`. Default off so plain-HTTP self-hosting (Docker on localhost) keeps working; never enable it without HTTPS in front |
| `DATABASE_URL` | yes on Render | `ecto://...` Postgres URL; unset -> SQLite at `DATABASE_PATH` |
| `DATABASE_USE_SSL` | no | SSL on unless `false`/`0` |
| `ENCRYPTION_KEY` | yes | Cloak key, 32 random bytes base64. Never change/lose |
| `SECRET_KEY_BASE` | yes | `mix phx.gen.secret` |
| `OIDC_ISSUER`, `OIDC_CLIENT_ID`, `OIDC_CLIENT_SECRET` | yes on public hosts when E2EE on | Auth0 |
| `RESEND_API_KEY`, `MAILER_FROM_EMAIL` | yes | boot fails without |
| `PORT` | no | default 4123 (Render sets it) |
| `POOL_SIZE` | no | default 10 |
| `MIX_ENV` | set in the image | `prod`; Hologram reads it at RUNTIME (unset -> wrong env and `/app` 404s). Don't unset it. |

## Build notes (verified without Docker, 2026-11-01)

Steps run locally in order: `deps.get --only prod`, `deps.compile`,
`assets.setup`, `npm install --prefix assets`, `compile` (Hologram bundles),
`assets.deploy`, `release`; the release was booted against a throwaway Postgres
with and without `E2EE=true`. Not verifiable here: the actual Docker image
build (apt/nodesource, base images) and Render itself.
