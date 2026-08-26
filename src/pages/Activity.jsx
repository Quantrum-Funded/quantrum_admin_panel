import React from "react";
import { useRpc } from "../lib/useRpc.js";
import { Card, Table, Chip, Stat, Loading } from "../components/ui.jsx";
import { AreaTrend, BarTrend, C } from "../components/charts.jsx";
import { KindChip } from "./Overview.jsx";
import { num, ago, dateTime, provider } from "../lib/format.js";

/**
 * Logins & activity.
 *
 * Worth knowing while reading this page: the database never used to keep login
 * history — signing in overwrote a single `updated_at` column. It is kept now,
 * but only from the day the tracking SQL was run. Anything before that is the
 * one-row-per-user backfill, so early history is thinner than it looks.
 */
export default function Activity({ days, refreshKey }) {
  const o  = useRpc("admin_overview",        { p_include_demo: false }, [refreshKey]);
  const ts = useRpc("admin_timeseries",      { p_days: days, p_include_demo: false }, [refreshKey]);
  const ac = useRpc("admin_recent_activity", { p_limit: 100 }, [refreshKey]);

  const d = o.data;
  const series = ts.data ?? [];

  return (
    <div style={{ display: "grid", gap: 16 }}>
      <div className="grid k4">
        <Stat label="Signed in today"      value={d ? num(d.active_today) : "—"} tone="up" live={d?.active_today > 0}
              foot={d ? `${num(d.logins_today)} sign-ins` : ""} />
        <Stat label="Signed in this week"  value={d ? num(d.active_7d) : "—"} tone="info"
              foot={d ? `${num(d.logins_7d)} sign-ins` : ""} />
        <Stat label="Signed in this month" value={d ? num(d.active_30d) : "—"} tone="violet"
              foot={d ? `${num(d.logins_30d)} sign-ins` : ""} />
        <Stat label="Last sign-in"         value={d ? ago(d.last_login_at) : "—"}
              foot={d ? dateTime(d.last_login_at) : ""} />
      </div>

      <div className="grid k2">
        <Card title="Sign-ins per day" note={`Total sign-ins vs distinct people · last ${days} days · IST`}>
          {ts.loading ? <Loading rows={1} height={230} /> : (
            <AreaTrend
              data={series}
              series={[
                { key: "logins",       label: "Sign-ins",        color: C.accent },
                { key: "active_users", label: "Distinct people", color: C.green },
              ]}
            />
          )}
        </Card>

        <Card title="New accounts" note={`First-ever sign-ins · last ${days} days`}>
          {ts.loading ? <Loading rows={1} height={230} /> : (
            <BarTrend data={series} series={[{ key: "signups", label: "New accounts", color: C.cyan }]} />
          )}
        </Card>
      </div>

      <Card
        title="Activity log"
        note="Every sign-in and lifecycle event, newest first"
        pad={false}
      >
        {ac.error && <div className="card-body"><div className="alert err">{ac.error}</div></div>}
        {ac.loading ? <div className="card-body"><Loading rows={8} height={34} /></div> : (
          <Table
            rows={ac.data ?? []}
            empty={
              <>Nothing recorded yet. Login history starts from the moment{" "}
              <code>01_admin_foundation.sql</code> was run.</>
            }
            columns={[
              { key: "email", label: "User", strong: true,
                render: (r) => r.email || r.name || <span className="mono">{r.user_id?.slice(0, 14)}…</span> },
              { key: "kind",     label: "Event",  render: (r) => <KindChip kind={r.kind} /> },
              { key: "provider", label: "Method", render: (r) => provider(r.provider) },
              { key: "account_type", label: "Account",
                render: (r) => (
                  <Chip tone={r.is_tester ? "violet" : r.account_type === "live" ? "green" : "grey"}>
                    {r.is_tester ? "tester" : r.account_type || "—"}
                  </Chip>
                ) },
              { key: "country", label: "Country", render: (r) => r.country || "—" },
              { key: "at", label: "When (IST)", align: "right", render: (r) => dateTime(r.at) },
              { key: "ago", label: "", align: "right", render: (r) => <span className="dim">{ago(r.at)}</span> },
            ]}
          />
        )}
      </Card>

      <div className="tip">
        <strong style={{ color: "var(--text-dim)" }}>How this is captured:</strong>{" "}
        signing in already writes to the users table on every sign-in, so a
        database trigger records each write instead of letting it overwrite the
        previous one. Nothing in the trading app had to change.
      </div>
    </div>
  );
}
