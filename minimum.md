# Debt Tracker

A self-hosted personal debt payoff tracker focused on **freeing up monthly cash flow as fast as possible**.

> The debts in the app on first run are **placeholder examples**. Edit them in the UI to match your own. Your real data is saved to a sqlite file that is gitignored.

## Features

**Tracking**
- Per-debt cards with balance, APR, minimum payment, and progress to payoff
- Log a single payment to one account, or log all balances at once
- Payment history showing which account each entry was applied to
- Dark and light themes (remembers your choice; respects system preference)

**Dynamic minimum payments**
- Revolving cards compute their minimum as `max(floor, rate% × balance)`, so it floats down automatically as you pay it off
- Installment loans (auto loans, payment plans, BNPL) use a fixed monthly payment
- Each debt's type, rate, and floor are editable per debt

**Interest modeling**
- Revolving-card balances accrue an estimated interest overlay between statements (marked `est.`), which reconciles whenever you log an actual balance
- Installment loans follow their fixed schedule and don't accrue an estimate
- Lifetime interest paid and "interest saved" vs. an interest-only baseline

**Payoff strategy & planning**
- Three payoff orders compared side by side: **Cash flow** (most monthly payment freed per dollar), **Snowball** (smallest balance first), and **Avalanche** (least total interest)
- Month-by-month simulation projects real payoff dates and total interest at your chosen monthly budget
- A "this month" action card tells you exactly what to pay and to which account
- "Monthly payments freed over time" chart visualizes the cash flow you're buying back
- Windfall allocator: enter a lump sum and see it cascade down your payoff order with the interest/time saved
- Low-rate installment loans can be flagged `excludeFromPlan` to keep them out of the consumer payoff plan while still counting in your totals

**Financial health**
- Credit utilization per card and overall (when credit limits are entered)
- Interest-vs-principal breakdown of everything you've paid