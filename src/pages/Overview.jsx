import React from "react";
import { useRpc } from "../lib/useRpc.js";
import { Card, Stat, Loading, Table, Chip, Empty } from "../components/ui.jsx";
import { AreaTrend, BarTrend, PnlTrend, C } from "../components/charts.jsx";
import { money, signedMoney, num, ago, provider, dateTime } from "../lib/format.js";

export default function Overview({ days, includeDemo, refreshKey }) {
  const o  = useRpc("admin_overview",       { p_include_demo: includeDemo }, [refreshKey]);
  const ts = useRpc("admin_timeseries",     { p_days: days, p_include_demo: includeDemo }, [refreshKey]);
  const ac = useRpc("admin_recent_activity",{ p_limit: 12 }, [refreshKey]);

  if (o.error) {
    return (
      <div className="alert err" style={{ maxWidth: 720 }}>
        <strong>Could not load.</strong> {o.error}
      </div>
    );
  }
  if (o.loading || !o.data) return <Loading rows={4} height={92} />;

  const d = o.data;
  const series = ts.data ?? [];

  return (
    <div style={{ display: "grid", gap: 16 }}>

      {/* --- the five numbers someone glances at ---------------------------- */}
      <div className="grid k5">
        <Stat
          label="Total users"
          value={num(d.users_total)}
          foot={`${num(d.users_7d)} joined in the last 7 days`}
        />
        <Stat
          label="Active today"
          value={num(d.active_today)}
          tone="up"
          live={d.active_today > 0}
          foot={`${num(d.logins_today)} sign-ins today`}
        />
        <Stat
          label="Active this week"
          value={num(d.active_7d)}
          tone="info"
          foot={`${num(d.active_30d)} in the last 30 days`}
        />
        <Stat
          label="Trades today"
          value={num(d.orders_today)}
          tone="violet"
          foot={`${num(d.traders_today)} ${d.traders_today === 1 ? "person" : "people"} trading`}
        />
        <Stat
          label="Revenue"
          value={money(d.revenue_total, { compact: true })}
          tone={Number(d.revenue_total) > 0 ? "up" : ""}
          foot={`${num(d.payments_captured)} payments captured`}
        />
      </div>

      {/* --- the charts ----------------------------------------------------- */}
      <div className="grid wide-left">
        <Card
          title="Users signing in"
          note={`Distinct people per day · last ${days} days · IST`}
        >
          {ts.loading ? <Loading rows={1} height={230} /> : (
            <AreaTrend
              data={series}
              series={[
                { key: "active_users", label: "Signed in", color: C.accent },
                { key: "signups",      label: "New signups", color: C.cyan },
              ]}
            />
          )}
        </Card>

        <Card title="Right now" note="Live state of the platform">
          <div style={{ display: "grid", gap: 13 }}>
            <Row label="Demo trials running"  value={num(d.demo_live_now)} tone="amber" />
            <Row label="Open positions"       value={num(d.open_positions)} />
            <Row label="Margin in use"        value={money(d.margin_used)} />
            <Row label="Active challenges"    value={num(d.challenges_active)} />
            <Row label="Last sign-in"         value={ago(d.last_login_at)} />
          </div>
          <div className="tip">
            Unrealised P&amp;L is never stored — it is marked live in the
            trader's browser, so a stored copy would be stale the moment it
            was written.
          </div>
        </Card>
      </div>

      <div className="grid k2">
        <Card title="Trades placed" note={`Filled orders per day · last ${days} days`}>
          {ts.loading ? <Loading rows={1} height={230} /> : (
            <BarTrend
              data={series}
              series={[{ key: "fills", label: "Filled orders", color: C.violet }]}
            />
          )}
        </Card>

        <Card
          title="Realised P&L"
          note={includeDemo ? "Includes demo accounts" : "Live accounts only"}
        >
          {ts.loading ? <Loading rows={1} height={230} /> : <PnlTrend data={series} />}
        </Card>
      </div>

      {/* --- the counters worth having, but not worth a chart --------------- */}
      <div className="grid k4">
        <Stat label="Demo trials started" value={num(d.demo_started)}
              foot={`${num(d.converted_total)} went on to pay`} tone="amber" />
        <Stat label="Total trades" value={num(d.orders_filled)}
              foot={`${num(d.orders_rejected)} rejected by the rule engine`} tone="violet" />
        <Stat
          label="Net realised P&L"
          value={signedMoney(d.realized_pnl)}
          tone={Number(d.realized_pnl) >= 0 ? "up" : "down"}
          foot={`Across ${num(d.traders_total)} traders`}
        />
        <Stat label="Waitlist" value={num(d.waitlist_total)}
              foot={`${num(d.ai_questions)} AI questions asked`} tone="info" />
      </div>

      {/* --- the live feed --------------------------------------------------- */}
      <Card
        title="Latest sign-ins"
        note="Newest first"
        pad={false}
        right={<span className="card-note">{dateTime(d.generated_at)}</span>}
      >
        {ac.loading ? <div className="card-body"><Loading rows={4} height={34} /></div> : (
          <Table
            rows={ac.data ?? []}
            empty={<>Nobody has signed in since login tracking was switched on.</>}
            columns={[
              { key: "email", label: "User", strong: true,
                render: (r) => r.email || r.name || <span className="mono">{r.user_id?.slice(0, 12)}…</span> },
              { key: "kind", label: "Event", render: (r) => <KindChip kind={r.kind} /> },
              { key: "provider", label: "Signed in with", render: (r) => provider(r.provider) },
              { key: "account_type", label: "Type",
                render: (r) => (
                  <Chip tone={r.is_tester ? "violet" : r.account_type === "live" ? "green" : "grey"}>
                    {r.is_tester ? "tester" : r.account_type || "—"}
                  </Chip>
                ) },
              { key: "at", label: "When", align: "right", render: (r) => ago(r.at) },
            ]}
          />
        )}
      </Card>
    </div>
  );
}

function Row({ label, value, tone }) {
  return (
    <div style={{ display: "flex", alignItems: "baseline", gap: 10 }}>
      <span style={{ color: "var(--text-dim)", fontSize: 13 }}>{label}</span>
      <span style={{ flex: 1, borderBottom: "1px dashed var(--border)", margin: "0 2px" }} />
      <span className={`num ${tone === "amber" ? "" : ""}`}
            style={{ fontWeight: 600, fontSize: 14 }}>{value}</span>
    </div>
  );
}

export function KindChip({ kind }) {
  const map = {
    login:        ["blue",   "signed in"],
    signup:       ["green",  "new account"],
    demo_start:   ["amber",  "started demo"],
    converted:    ["violet", "paid"],
    account_type: ["grey",   "type changed"],
    tester:       ["violet", "tester granted"],
    settings:     ["grey",   "settings saved"],
  };
  const [tone, label] = map[kind] ?? ["grey", kind];
  return <Chip tone={tone}>{label}</Chip>;
}
