import React from "react";
import { useRpc } from "../lib/useRpc.js";
import { Card, Table, Stat, Loading, StatusChip, Chip } from "../components/ui.jsx";
import { PnlTrend, BarTrend, Donut, Legend, C } from "../components/charts.jsx";
import { num, money, signedMoney, pct, dateTime, ago } from "../lib/format.js";

export default function Trading({ days, includeDemo, refreshKey }) {
  const o  = useRpc("admin_overview",        { p_include_demo: includeDemo }, [refreshKey]);
  const ts = useRpc("admin_timeseries",      { p_days: days, p_include_demo: includeDemo }, [refreshKey]);
  const t  = useRpc("admin_trading_summary", { p_limit: 10, p_include_demo: includeDemo }, [refreshKey]);

  const d = o.data;
  const series = ts.data ?? [];
  const s = t.data;

  return (
    <div style={{ display: "grid", gap: 16 }}>
      <div className="grid k5">
        <Stat label="Trades placed" value={d ? num(d.orders_filled) : "—"} tone="violet"
              foot={d ? `${num(d.orders_today)} today` : ""} />
        <Stat label="People trading" value={d ? num(d.traders_total) : "—"} tone="info"
              foot={d ? `${num(d.traders_today)} today` : ""} />
        <Stat
          label="Net realised P&L"
          value={d ? signedMoney(d.realized_pnl) : "—"}
          tone={d && Number(d.realized_pnl) >= 0 ? "up" : "down"}
          foot={d ? `${signedMoney(d.pnl_today)} today` : ""}
        />
        <Stat label="Open positions" value={d ? num(d.open_positions) : "—"}
              foot={d ? `${money(d.margin_used)} margin in use` : ""} />
        <Stat label="Rejected orders" value={d ? num(d.orders_rejected) : "—"} tone="down"
              foot="Stopped by the rule engine" />
      </div>

      <div className="grid k2">
        <Card title="Realised P&L by day"
              note={includeDemo ? "Includes demo accounts" : "Live accounts only · IST"}>
          {ts.loading ? <Loading rows={1} height={230} /> : <PnlTrend data={series} />}
        </Card>
        <Card title="Trades vs rejections" note={`Last ${days} days`}>
          {ts.loading ? <Loading rows={1} height={230} /> : (
            <BarTrend
              data={series}
              series={[
                { key: "fills",      label: "Filled",   color: C.violet },
                { key: "rejections", label: "Rejected", color: C.red },
              ]}
            />
          )}
        </Card>
      </div>

      <div className="grid wide-left">
        <Card title="Top traders" note="Ranked by realised P&L" pad={false}>
          {t.loading ? <div className="card-body"><Loading rows={5} height={34} /></div> : (
            <Table
              rows={s?.top_traders ?? []}
              empty={<>Nobody has filled an order yet.</>}
              columns={[
                { key: "email", label: "Trader", strong: true,
                  render: (r) => r.email || r.name || <span className="mono">{r.user_id?.slice(0, 12)}…</span> },
                { key: "fills",  label: "Fills",  align: "right", render: (r) => num(r.fills) },
                { key: "closing_orders", label: "Closes", align: "right", render: (r) => num(r.closing_orders) },
                { key: "win_rate_pct", label: "Win rate", align: "right",
                  render: (r) => r.win_rate_pct == null ? "—" : pct(r.win_rate_pct) },
                { key: "realized_pnl", label: "P&L", align: "right",
                  render: (r) => (
                    <span className={Number(r.realized_pnl) > 0 ? "up-text"
                          : Number(r.realized_pnl) < 0 ? "down-text" : "dim"}>
                      {signedMoney(r.realized_pnl)}
                    </span>
                  ) },
              ]}
            />
          )}
          <div className="card-body" style={{ paddingTop: 0 }}>
            <div className="tip">
              Win rate is per <em>closing order</em>, not per round trip. Pairing
              an entry to its exit needs the <code>trades</code> table, which has
              no writer yet — so holding time and MFE/MAE are not available.
            </div>
          </div>
        </Card>

        <Card title="Order outcomes" note="Every order ever placed">
          {t.loading ? <Loading rows={1} height={210} /> : (
            <>
              <Donut data={s?.status_mix ?? []} nameKey="status" valueKey="count" />
              <Legend data={s?.status_mix ?? []} nameKey="status" valueKey="count" />
            </>
          )}
        </Card>
      </div>

      <div className="grid k2">
        <Card title="Most traded contracts" note="By number of fills" pad={false}>
          {t.loading ? <div className="card-body"><Loading rows={5} height={34} /></div> : (
            <Table
              rows={s?.symbols ?? []}
              empty={<>No fills yet.</>}
              columns={[
                { key: "symbol", label: "Symbol", strong: true },
                { key: "instrument", label: "Type",
                  render: (r) => <Chip tone={r.instrument === "FUT" ? "blue" : r.instrument === "CE" ? "green" : "red"}>{r.instrument}</Chip> },
                { key: "fills", label: "Fills", align: "right", render: (r) => num(r.fills) },
                { key: "lots",  label: "Lots",  align: "right", render: (r) => num(r.lots) },
                { key: "realized_pnl", label: "P&L", align: "right",
                  render: (r) => (
                    <span className={Number(r.realized_pnl) > 0 ? "up-text"
                          : Number(r.realized_pnl) < 0 ? "down-text" : "dim"}>
                      {signedMoney(r.realized_pnl)}
                    </span>
                  ) },
              ]}
            />
          )}
        </Card>

        <Card title="Why orders get rejected" note="The rule engine's own words" pad={false}>
          {t.loading ? <div className="card-body"><Loading rows={5} height={34} /></div> : (
            <Table
              rows={s?.rejections ?? []}
              empty={<>No order has been rejected.</>}
              columns={[
                { key: "reason", label: "Reason", strong: true,
                  render: (r) => <span style={{ whiteSpace: "normal" }}>{r.reason}</span> },
                { key: "count", label: "Times", align: "right", render: (r) => num(r.count) },
              ]}
            />
          )}
        </Card>
      </div>

      <Card title="Open positions right now" note="Live exposure across every account" pad={false}>
        {t.loading ? <div className="card-body"><Loading rows={4} height={34} /></div> : (
          <Table
            rows={s?.open_positions ?? []}
            empty={<>Nothing is open right now.</>}
            columns={[
              { key: "email", label: "Trader", strong: true, render: (r) => r.email || "—" },
              { key: "symbol", label: "Symbol" },
              { key: "side", label: "Side",
                render: (r) => <Chip tone={r.side === "BUY" ? "green" : "red"}>{r.side}</Chip> },
              { key: "lots", label: "Lots", align: "right", render: (r) => num(r.lots) },
              { key: "entry_price", label: "Entry", align: "right", render: (r) => money(r.entry_price) },
              { key: "margin_used", label: "Margin", align: "right", render: (r) => money(r.margin_used) },
              { key: "opened_at", label: "Open for", align: "right", render: (r) => ago(r.opened_at) },
              ...(includeDemo ? [{ key: "is_simulated", label: "", render: (r) => r.is_simulated ? <Chip tone="amber">demo</Chip> : null }] : []),
            ]}
          />
        )}
      </Card>

      <Card title="Latest orders" note="Newest first" pad={false}>
        {t.loading ? <div className="card-body"><Loading rows={6} height={34} /></div> : (
          <Table
            rows={s?.recent_orders ?? []}
            empty={<>No orders yet.</>}
            columns={[
              { key: "created_at", label: "When (IST)", render: (r) => dateTime(r.created_at) },
              { key: "email", label: "Trader", strong: true, render: (r) => r.email || "—" },
              { key: "symbol", label: "Symbol" },
              { key: "side", label: "Side",
                render: (r) => <Chip tone={r.side === "BUY" ? "green" : "red"}>{r.side}</Chip> },
              { key: "order_type", label: "Type" },
              { key: "lots", label: "Lots", align: "right", render: (r) => num(r.lots) },
              { key: "fill_price", label: "Fill", align: "right",
                render: (r) => r.fill_price == null ? "—" : money(r.fill_price) },
              { key: "status", label: "Status", render: (r) => <StatusChip value={r.status} /> },
              { key: "realized_pnl", label: "P&L", align: "right",
                render: (r) => r.realized_pnl == null ? <span className="dim">—</span> : (
                  <span className={Number(r.realized_pnl) > 0 ? "up-text" : "down-text"}>
                    {signedMoney(r.realized_pnl)}
                  </span>
                ) },
            ]}
          />
        )}
        <div className="card-body" style={{ paddingTop: 0 }}>
          <div className="tip">
            A dash under P&amp;L means the order opened a position rather than
            closing one — P&amp;L is only booked when a fill nets against an
            opposite position.
          </div>
        </div>
      </Card>
    </div>
  );
}
