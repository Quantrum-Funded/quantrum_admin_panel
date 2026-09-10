# Quantrum Admin Panel

Repository: https://github.com/Quantrum-Funded/quantrum_admin_panel

Production domain: https://admin.quantrumfunded.com/

A read-only dashboard over the Quantrum Supabase database, for the people who
need the numbers but should never need to write SQL.

It is a **separate app**. Plain React + Vite, its own `package.json`, its own
`node_modules`, its own login. It imports nothing from the Next.js app and the
Next.js app imports nothing from it. Deleting this folder would leave the
trading platform exactly as it is.

---

## Setup — three steps, about five minutes

### 1. Run the SQL

SQL scripts are kept locally and excluded from Git. For a fresh clone, obtain
the scripts from the project owner before following this setup step.

Supabase dashboard → **SQL Editor**, and run these five in order. Each is a
few KB, self-contained, safe to re-run, and prints what it created:

| File | What it adds |
|---|---|
| `sql/01_admin_foundation.sql` | `admin_users`, `user_login_events`, the sign-in trigger, backfill |
| `sql/02a_read_core.sql` | Overview page |
| `sql/02b_activity.sql` | The sign-in feed (Overview + Logins) |
| `sql/02c_trading.sql` | Trading + Funnel pages |
| `sql/04_user_filter.sql` | The user picker in the header, and `p_user_id` on the five reads |

**Why five small files and not one big one.** There is a `sql/RUN_THIS.sql`
that concatenates all of them, but it is ~50 KB, and a paste that long can be
truncated on the way into the editor. A truncated paste **fails silently**: the
statements that did arrive succeed and commit, so the editor reports no error
while half the functions are missing — which looks exactly like the SQL never
ran. The small files make that impossible to miss.

**`sql/00_check.sql`** answers "what is actually installed?" — it lists every
table, trigger, function and grant the dashboard needs, marks each present or
missing, names the file that creates anything missing, and changes nothing.
Run it whenever the panel says something is missing.

### 2. Create your admin login

Supabase dashboard → **Authentication → Users → Add user**. Give it an email
and password, and tick **Auto Confirm User**. Do this for each person on the
team.

Then put them on the allow-list — SQL Editor again:

```sql
insert into public.admin_users (user_id, email, role)
select id, email, 'owner' from auth.users where email = 'you@quantrum.in'
on conflict (user_id) do nothing;
```

`owner` and `viewer` currently see the same things; the column is there so a
narrower role can be added without a migration.

To remove someone: `delete from public.admin_users where email = '...';` — it
takes effect on their next request.

### 3. Run it

```bash
cd admin-panel
npm install
npm run dev          # http://localhost:5273
```

`.env` already holds the Supabase URL and anon key (copied from
`Quantrum_backend/.env`). `.env.example` is the template if you need to
recreate it.

---

## What it shows

| Page | What is on it |
|---|---|
| **Overview** | Total users, active today / this week / this month, trades today, revenue, the sign-in and trading charts, live state, and the latest sign-ins |
| **Logins** | DAU / WAU / MAU, sign-ins per day, new accounts per day, and the full activity log |
| **Trading** | Trades and P&L by day, top traders, most-traded contracts, why orders get rejected, open positions, latest orders |
| **Funnel** | Signed up → came back → started demo → placed a trade → paid, plus provider / account-type / country splits |

Three controls in the header apply to every page:

- **All users** — the user picker. Leave it alone for platform totals, or pick
  somebody and every tile, chart and table narrows to them. See below.
- **Include demo accounts** — off by default. The demo seeds six *fabricated*
  daily-P&L rows per trial that nobody traded, so leaving them in would quietly
  corrupt every average. Turn it on to look at demo activity deliberately.
- **7d / 30d / 90d** — the window every chart uses.

---

## Looking at one person

The panel's numbers are platform totals, which answer "how are we doing" and
are no help at all with the question ops actually gets: *what happened with
this person?* Before the picker, that meant scrolling the activity log with a
finger on the screen.

Click **All users** in the header, type an email, a name or a user id — or type
nothing, because it opens on the twenty people who signed in most recently,
which is usually where the answer is. Pick somebody and:

- a strip appears under the header naming them, with their chips (live/trial,
  tester, paid, country, provider) and their joined / last-seen / sign-ins /
  trades / realised P&L. It stays on screen, so a screenshot of any page says
  who it is about;
- **Overview** swaps its five headline tiles for sign-ins, last seen, trades,
  realised P&L and what they paid;
- **Logins** becomes their timeline — every sign-in, demo start, conversion and
  settings save, in order;
- **Trading** becomes their fills, their win rate, their symbols, their
  rejection reasons and their open positions;
- **Funnel** stops being a funnel and becomes five yes/no rows: which of the
  steps they took, and the first one they did not.

“Show everyone” on the strip, or the ✕ next to the picker, puts it back.

Two things deliberately go blank rather than wrong while a person is picked:
**waitlist** and **AI questions**. The waitlist is people who have *not* signed
up, so it cannot belong to one of them, and showing a platform total next to
five personal ones is how a screenshot ends up in the wrong meeting.

**It is still read-only.** The picker searches; it does not edit anybody.

---

## Where login times come from

Before this panel, **the database kept no login history at all**. `users` has
`created_at` and `updated_at`; `user_sessions` was specified but never given a
writer. Every sign-in overwrote the last one's timestamp.

Signing in *does* already write to Postgres, though: `POST /api/auth/session`
runs on every sign-in and calls `app_ensure_user`, whose
`INSERT ... ON CONFLICT DO UPDATE` touches the row every single time. So the
write was always there — only the history was being thrown away.

`01_admin_foundation.sql` adds an `AFTER` trigger that keeps each of those
writes as a row in `public.user_login_events`, and classifies it: a plain
sign-in, a first-ever signup, a demo start, a conversion, a settings save. The
classification is exact rather than a guess, because each of those non-login
writes changes a specific column and a sign-in changes none of them.

**Nothing in the trading app changed.** No route, no Worker code, nothing to
deploy. Run the SQL and the next sign-in is recorded.

Two honest limits:

- **History starts the day you run the SQL.** Existing users are backfilled
  with one `signup` at their `created_at` and one `login` at their
  `updated_at` — that is all the old schema retained, and it cannot be
  reconstructed further back.
- **The trigger swallows its own errors** on purpose. A dashboard must never
  be the reason somebody cannot sign in.

---

## How access works

The panel ships the Supabase **anon key** in its JS bundle, which is what that
key is for. It grants nothing on its own: this schema revokes `anon` from every
table, so the anon key reads zero rows.

Everything the dashboard reads goes through `admin_*` functions that are:

- `security definer`, so they can read past RLS;
- granted to `authenticated` only, and explicitly revoked from `PUBLIC`;
- gated on `public.is_admin()` — the caller's Supabase Auth uid must be on the
  allow-list, or the call raises.

So the panel is protected by an admin password, not by a secret in a file. If
the anon key leaked tomorrow it would still read nothing.

**Never put `SUPABASE_SERVICE_ROLE_KEY` in this app's `.env`.** It bypasses RLS
entirely, and a `VITE_` prefix would ship a full-database credential to every
browser that loads the page.

### The panel cannot write

There is no insert, update or delete anywhere in this app, and no `admin_*`
function performs one. It is a window, not a control room.

---

## Numbers that need a caveat

The dashboard labels these in place; they are collected here for reference.

- **Win rate is per closing order, not per round trip.** Pairing an entry to
  its exit needs the `trades` table, which has no writer yet. Holding time,
  MFE/MAE and true round-trip win rate are not available.
- **Unrealised P&L is never stored** — it is marked live in the trader's
  browser. Every P&L figure here is realised only, which is why the panel's
  number can differ from the terminal's by exactly the open-position mark.
- **Fill prices come from the browser** (`fill_price_source = 'client'`). Good
  enough for behaviour, not exchange-grade.
- **Days are IST session dates.** A 21:00 IST sign-in belongs to that evening,
  not the next UTC morning.
- **Money is rounded to whole rupees** by the app before it reaches Postgres.

---

## Deploying it

`npm run build` produces a static `dist/`. Host it anywhere — Cloudflare Pages,
Netlify, an S3 bucket. There is no server component.

Connect the hosting project to `Quantrum-Funded/quantrum_admin_panel` and deploy
the `main` branch using `npm run build` with `dist` as the output directory.
Configure `admin.quantrumfunded.com` as the custom domain in the hosting
provider and add the DNS records it supplies. The canonical URL in
`index.html` identifies this domain; it does not configure hosting or DNS.

Because it is a plain static site protected by a login, put it behind
Cloudflare Access or an equivalent if you want a second lock on the door.
`index.html` already carries `noindex, nofollow`.

## Files

```
admin-panel/
  sql/00_check.sql              what is installed? changes nothing
  sql/01_admin_foundation.sql   admin allow-list + login tracking + backfill
  sql/02a_read_core.sql         Overview
  sql/02b_activity.sql          the sign-in feed
  sql/02c_trading.sql           Trading + Funnel
  sql/04_user_filter.sql        the user picker + p_user_id on the five reads
  sql/RUN_THIS.sql              all five concatenated (~50 KB — see the warning)
  src/supabase.js               client + the single rpc() helper
  src/App.jsx                   auth gate, sidebar, global filters
  src/pages/                    Overview, Activity, Trading, Funnel
  src/components/               shared UI, charts, the logo, the user picker
  src/lib/format.js             money / dates / IST / "3 minutes ago"
```
