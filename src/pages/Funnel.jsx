import React from "react";
import { useRpc } from "../lib/useRpc.js";
import { Card, Loading, Stat } from "../components/ui.jsx";
import { Donut, Legend } from "../components/charts.jsx";
import { num, pct, money } from "../lib/format.js";
import { provider } from "../lib/format.js";

/**
 * The funnel: signed up -> came back -> tried the demo -> actually traded ->
 * paid. Percentages are of the top of the funnel, which is the number an
 * operator actually compares week to week.
 *
 * Filtered to one person the same five rows stop being a funnel and become a
 * biography: which of those things they did, and — the useful half — the first
 * one they did not. Every bar is 100% or 0%, so the percentage column is
 * dropped rather than left repeating itself down the card.
 */
export default function Funnel({ refreshKey, includeDemo, userId }) {
  const f = useRpc("admin_funnel", { p_user_id: userId }, [refreshKey]);
  const o = useRpc("admin_overview", { p_include_demo: includeDemo, p_user_id: userId }, [refreshKey]);
  const one = Boolean(userId);

  if (f.error) return <div className="alert err">{f.error}</div>;
  if (f.loading || !f.data) return <Loading rows={3} height={110} />;

  const d = f.data;
  const o2 = o.data;
  const top = Math.max(Number(d.signed_up) || 0, 1);

  const steps = [
    { label: "Signed up",       value: d.signed_up,    hint: "Created an account" },
    { label: "Came back",       value: d.returned,     hint: "Signed in more than once" },
    { label: "Started demo",    value: d.started_demo, hint: "Opened the 15-minute trial" },
    { label: "Placed a trade",  value: d.placed_order, hint: "Filled at least one real order" },
    { label: "Paid",            value: d.paid,         hint: "Bought a challenge" },
  ];

  const providers = (d.by_provider ?? []).map((p) => ({ ...p, provider: provider(p.provider) }));

  return (
    <div style={{ display: "grid", gap: 16 }}>
      <div className="grid k4">
        <Stat label={one ? "Came back" : "Signed up"}
              value={one ? yesNo(d.returned) : num(d.signed_up)}
              foot={one ? "signed in more than once" : ""} />
        <Stat label="Tried the demo" value={one ? yesNo(d.started_demo) : num(d.started_demo)} tone="amber"
              foot={one ? "" : pct((Number(d.started_demo) / top) * 100) + " of signups"} />
        <Stat label="Actually traded" value={one ? yesNo(d.placed_order) : num(d.placed_order)} tone="violet"
              foot={one ? "at least one live fill" : pct((Number(d.placed_order) / top) * 100) + " of signups"} />
        <Stat label="Paid" value={one ? yesNo(d.paid) : num(d.paid)} tone="up"
              foot={o2 ? money(o2.revenue_total) + " collected" : ""} />
      </div>

      <Card title={one ? "How far they got" : "Signup funnel"}
            note={one
              ? "The five steps, and the first one they did not take"
              : "Each bar is a share of everyone who ever signed up"}>
        <div style={{ paddingTop: 4 }}>
          {steps.map((s) => {
            const v = Number(s.value) || 0;
            const share = (v / top) * 100;
            return (
              <div className="funnel-row" key={s.label}>
                <div className="funnel-name">
                  {s.label}
                  <div style={{ fontSize: 11, color: "var(--text-mute)" }}>{s.hint}</div>
                </div>
                <div className="funnel-bar">
                  <div className={`funnel-fill ${one && v === 0 ? "empty" : ""}`}
                       style={{ width: `${Math.max(share, 3)}%` }}>
                    <span className="num">{one ? (v > 0 ? "yes" : "") : num(v)}</span>
                  </div>
                </div>
                {one
                  ? <div className="funnel-pct">{v > 0 ? "" : "no"}</div>
                  : <div className="funnel-pct num">{pct(share, 0)}</div>}
              </div>
            );
          })}
        </div>
        <div className="tip">
          “Placed a trade” counts live accounts only — demo orders are excluded
          here on purpose, because the point of this {one ? "row" : "chart"} is
          who did something real.
        </div>
      </Card>

      <div className="grid k3">
        <Card title={one ? "How they sign in" : "How people sign in"} note="Firebase auth provider">
          <Donut data={providers} nameKey="provider" valueKey="count" />
          <Legend data={providers} nameKey="provider" valueKey="count" />
        </Card>

        <Card title="Account type" note="Trial accounts never see a payment form">
          <Donut data={d.by_account_type ?? []} nameKey="account_type" valueKey="count" />
          <Legend data={d.by_account_type ?? []} nameKey="account_type" valueKey="count" />
        </Card>

        <Card title={one ? "Where they are" : "Where everyone is"} note="Declared country">
          <Donut data={d.by_country ?? []} nameKey="country" valueKey="count" />
          <Legend data={d.by_country ?? []} nameKey="country" valueKey="count" />
        </Card>
      </div>
    </div>
  );
}

/** One person cannot be 43% converted. Filtered, the funnel answers yes or no. */
function yesNo(v) {
  return Number(v) > 0 ? "Yes" : "No";
}
