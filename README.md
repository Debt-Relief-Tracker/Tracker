# DebtReliefTracker

A self-hosted personal debt payoff tracker focused on **freeing up monthly
cash flow as fast as possible**. Built with Phoenix LiveView; ships as a
single Docker image with SQLite by default (Postgres optional), and works
fully single-user with no login, or shared between people via an external
OIDC provider.

> On first run the app seeds a few **placeholder debts** so the dashboard
> isn't empty. Edit or delete them in the UI to match your own -- your real
> data is saved to a SQLite file that's gitignored (or to Postgres, if
> configured).

## Features

**Tracking**
- Per-debt cards with balance, APR, minimum payment, and progress to payoff
- Log a single payment to one account, or log all balances at once
- Payment history showing which account each entry was applied to
- Dark and light themes (remembers your choice; respects system preference)

**Dynamic minimum payments**
- Revolving cards (credit cards) compute their minimum as
  `max(floor, rate% × balance)`, so it floats down automatically as you pay
  it off
- Installment loans (auto loans, payment plans, BNPL) use a fixed monthly
  payment, optionally with a due day and auto-logged payments (off, confirm
  first, or fully automatic)
- Each debt's type, rate, and floor are editable per debt

**Interest modeling**
- Revolving-card balances accrue an estimated interest overlay between
  statements (marked `est.`), which reconciles whenever you log an actual
  balance
- Installment loans follow their fixed schedule and don't accrue an estimate
- Lifetime interest paid and "interest saved" vs. an interest-only baseline

**Payoff strategy & planning**
- Three payoff orders compared side by side: **Cash flow** (most monthly
  payment freed per dollar), **Snowball** (smallest balance first), and
  **Avalanche** (least total interest)
- Month-by-month simulation projects real payoff dates and total interest at
  your chosen monthly budget
- A "this month" action card tells you exactly what to pay and to which
  account
- "Monthly payments freed over time" chart visualizes the cash flow you're
  buying back
- Windfall allocator: enter a lump sum and see it cascade down your payoff
  order with the interest/time saved
- Low-rate installment loans can be excluded from the payoff plan while
  still counting toward your totals

**Financial health**
- Credit utilization per card and overall (when credit limits are entered)
- Interest-vs-principal breakdown of everything you've paid, and a full
  activity log of every change
- Multi-currency display (`USD`/`EUR`/`GBP`/`CAD`/`AUD`/`JPY`)
- CSV export of your debts and payment history

All charts are real [Chart.js](https://www.chartjs.org/) charts, bundled
locally via esbuild -- no CDN, so the dashboard works fully offline/self-hosted.

## Accounts & sharing

By default there's **no login** -- a single implicit workspace holds all
your debts, and the app looks and behaves like a single-user tool. Point it
at an external OIDC provider (`OIDC_ISSUER`, `OIDC_CLIENT_ID`,
`OIDC_CLIENT_SECRET`) to turn on real login: each person gets their own
workspace, and an owner can share theirs with another logged-in person by
email (from the dashboard header). See
[`docs/architecture/0002-auth-and-sharing-model.md`](docs/architecture/0002-auth-and-sharing-model.md)
for the full design.

## Local development

* Run `mix setup` to install everything: Elixir deps, the SQLite database,
  Tailwind/esbuild, and the JS packages under `assets/` (`npm install`)
* Start Phoenix endpoint with `mix phx.server` or inside IEx with `iex -S mix phx.server`

Now you can visit [`localhost:4123`](http://localhost:4123) from your browser.

## Deployment (Docker)

The app is distributed as a single Docker image, self-hosted-first:

```sh
cp .env.example .env   # fill in SECRET_KEY_BASE (mix phx.gen.secret)
docker compose up -d --build
```

Data persists to `./data` on the host (bind-mounted to `/data` in the
container), using a SQLite file by default -- no external database required.
To use Postgres instead, set `POSTGRES_PASSWORD` in `.env` and run:

```sh
docker compose -f docker-compose.yml -f docker-compose.postgres.yml up -d --build
```

See [`docs/architecture/0001-dual-database-adapter.md`](docs/architecture/0001-dual-database-adapter.md)
and [`docs/architecture/0003-self-hosting-and-docker.md`](docs/architecture/0003-self-hosting-and-docker.md)
for how the adapter switch and image are built. `.env.example` documents
every supported environment variable, including the optional OIDC vars
above.

## Email

Transactional email (workspace invites/share notices) is sent via
[Resend](https://resend.com) through Swoosh. In dev/test, mail is captured
locally and never actually sent -- no Resend account needed (view it at
`/dev/mailbox` in dev).

**In production, Resend is required.** `RESEND_API_KEY` and
`MAILER_FROM_EMAIL` must be set or the app fails to boot; `MAILER_FROM_NAME`
is optional. See `.env.example` and `config/runtime.exs` for details.
