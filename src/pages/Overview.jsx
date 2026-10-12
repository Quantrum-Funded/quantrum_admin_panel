import React, { useState } from "react";
import { useRpc } from "../lib/useRpc.js";
import { Card, Stat, Loading, Table, Chip, Empty } from "../components/ui.jsx";
import { AreaTrend, BarTrend, PnlTrend, C } from "../components/charts.jsx";
import { useFeedFilter, FeedFilters, EventCell, noMatch } from "../components/FeedFilters.jsx";
import { money, signedMoney, num, ago, provider, dateTime } from "../lib/format.js";

export default function Overview({ days, includeDemo, refreshKey, userId }) {
  const o  = useRpc("admin_overview",       { p_include_demo: includeDemo, p_user_id: userId }, [refreshKey]);
  const ts = useRpc("admin_timeseries",     { p_days: days, p_include_demo: includeDemo, p_user_id: userId }, [refreshKey]);
  // Deeper than the card draws on purpose. The feed shows the newest handful,
  // but the Event filter above it has to be able to find the one `paid` event
  // in a page of sign-ins — filtering twelve rows would mostly find nothing.
  const ac = useRpc("admin_recent_activity",{ p_limit: 80, p_user_id: userId }, [refreshKey]);

  // With a filter on, half these tiles would read 0 or 1 and mean nothing —
  // "active today: 1" is not a statistic, it is a yes. So the front page asks
  // a different set of questions about one person than it does about all of
  // them, rather than showing the same five tiles with the life taken out.
  const one = Boolean(userId);

  // Filtered, the card is that person's whole timeline and shows more of it.
  // capFiltered is the same idea one step further: unfiltered this card is a
  // glance and twelve rows is the right length, but somebody who has just
  // asked for every `paid` event wants every one it found, not twelve of them.
  const f = useFeedFilter(ac.data, { cap: one ? 40 : 12, capFiltered: 60 });

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
        {one ? (
          <>
            <Stat
              label="Sign-ins"
              value={num(d.logins_30d)}
              tone="info"
              foot={`in the last 30 days · ${num(d.logins_today)} today`}
            />
            <Stat
              label="Last seen"
              value={ago(d.last_login_at)}
              tone={d.active_today > 0 ? "up" : ""}
              live={d.active_today > 0}
              foot={dateTime(d.last_login_at)}
            />
            <Stat
              label="Trades"
              value={num(d.orders_filled)}
              tone="violet"
              foot={`${num(d.orders_today)} today · ${num(d.orders_rejected)} rejected`}
            />
            <Stat
              label="Realised P&L"
              value={signedMoney(d.realized_pnl)}
              tone={Number(d.realized_pnl) >= 0 ? "up" : "down"}
              foot={`${signedMoney(d.pnl_today)} today`}
            />
            <Stat
              label="Paid"
              value={money(d.revenue_total, { compact: true })}
              tone={Number(d.revenue_total) > 0 ? "up" : ""}
              foot={Number(d.payments_captured) > 0
                ? `${num(d.payments_captured)} payment${Number(d.payments_captured) === 1 ? "" : "s"} captured`
                : "never paid"}
            />
          </>
        ) : (
          <>
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
          </>
        )}
      </div>

      {!one && (
        <Card title="Waitlist" note="All time">
          <div className="waitlist-summary">
            <div className="waitlist-count num">{d.waitlist_total == null ? "—" : num(d.waitlist_total)}</div>
            <div className="waitlist-description">People added to the waitlist</div>
            <a className="waitlist-jump" href="#waitlist-leads">View people ↓</a>
          </div>
        </Card>
      )}

      {/* --- the charts ----------------------------------------------------- */}
      <div className="grid wide-left">
        <Card
          title={one ? "When they sign in" : "Users signing in"}
          note={one
            ? `Their sign-ins per day · last ${days} days · IST`
            : `Distinct people per day · last ${days} days · IST`}
        >
          {ts.loading ? <Loading rows={1} height={230} /> : (
            <AreaTrend
              data={series}
              series={one ? [
                { key: "logins", label: "Sign-ins", color: C.accent },
              ] : [
                { key: "active_users", label: "Signed in", color: C.accent },
                { key: "signups",      label: "New signups", color: C.cyan },
              ]}
            />
          )}
        </Card>

        <Card title="Right now" note={one ? "Where this account stands" : "Live state of the platform"}>
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
        {one ? (
          <>
            <Stat label="Challenges" value={num(d.challenges_total)} tone="info"
                  foot={`${num(d.challenges_active)} active · ${num(d.challenges_passed)} passed · ${num(d.challenges_failed)} failed`} />
            <Stat label="Rejected orders" value={num(d.orders_rejected)} tone="down"
                  foot="Stopped by the rule engine" />
            <Stat label="Open positions" value={num(d.open_positions)}
                  foot={`${money(d.margin_used)} margin in use`} />
            <Stat label="Demo trials" value={num(d.demo_started)} tone="amber"
                  foot={Number(d.converted_total) > 0 ? "went on to pay" : "has not converted"} />
          </>
        ) : (
          <>
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
            <Stat label="AI questions" value={num(d.ai_questions)} tone="info"
                  foot="Asked across the platform" />
          </>
        )}
      </div>

      {/* --- the live feed --------------------------------------------------- */}
      <Card
        title={one ? "Everything this account has done" : "Latest sign-ins"}
        note="Newest first"
        pad={false}
        right={<span className="card-note">{dateTime(d.generated_at)}</span>}
      >
        {ac.loading ? <div className="card-body"><Loading rows={4} height={34} /></div> : (
          <>
          <FeedFilters f={f} hideUser={one} />
          <Table
            rows={f.rows}
            emptyTitle={f.active ? "No events match" : undefined}
            empty={f.active ? noMatch(f) : one
              ? <>Nothing recorded for this account since login tracking was switched on.</>
              : <>Nobody has signed in since login tracking was switched on.</>}
            columns={[
              { key: "email", label: "User", strong: true,
                render: (r) => r.email || r.name || <span className="mono">{r.user_id?.slice(0, 12)}…</span> },
              { key: "kind", label: "Event", render: (r) => <EventCell row={r} /> },
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
          </>
        )}
      </Card>

      {!one && <WaitlistSection total={d.waitlist_total} refreshKey={refreshKey} />}
    </div>
  );
}

const WAITLIST_PAGE_SIZE = 25;

function WaitlistSection({ total, refreshKey }) {
  const [page, setPage] = useState(0);
  const leads = useRpc("admin_waitlist_leads", {
    p_limit: WAITLIST_PAGE_SIZE,
    p_offset: page * WAITLIST_PAGE_SIZE,
  }, [refreshKey]);
  const rows = leads.data ?? [];
  const hasNext = rows.length === WAITLIST_PAGE_SIZE &&
    (total == null || (page + 1) * WAITLIST_PAGE_SIZE < Number(total));

  return (
    <section id="waitlist-leads" className="waitlist-section">
    <Card title="Waitlist people" note="Newest first · select a person to see their answers" pad={false}>
      {leads.error ? (
        <div className="card-body"><div className="alert err">Could not load waitlist details. {leads.error}</div></div>
      ) : leads.loading ? (
        <div className="card-body"><Loading rows={3} height={52} /></div>
      ) : (
        <>
          {rows.length === 0 ? <Empty title="No waitlist entries yet">New waitlist signups will appear here.</Empty> : (
            <div className="waitlist-list">
              <div className="waitlist-list-head" aria-hidden="true">
                <span>Person</span><span>Interest</span><span>Would pay</span><span>Added</span><span />
              </div>
              {rows.map((r) => (
                <details className="waitlist-person" key={r.id}>
                  <summary className="waitlist-person-summary">
                    <span className="waitlist-person-contact">
                      <strong>{r.name || r.email || r.phone || "Unnamed lead"}</strong>
                      <span>{[r.email && r.name ? r.email : null, r.phone].filter(Boolean).join(" · ") || "No contact details"}</span>
                    </span>
                    <span className="waitlist-person-interest">{[r.interest_category, r.interest_tier].filter(Boolean).join(" · ") || "—"}</span>
                    <span className="waitlist-person-pay"><Answer value={r.would_pay_fee} /></span>
                    <span className="waitlist-person-date">{dateTime(r.created_at)}</span>
                    <span className="waitlist-person-chevron" aria-hidden="true">⌄</span>
                  </summary>
                  <div className="waitlist-person-extra">
                    <div><span>Email</span><strong>{r.email || "—"}</strong></div>
                    <div><span>Phone</span><strong>{r.phone || "—"}</strong></div>
                    <div><span>Source</span><strong>{r.source || "—"}</strong></div>
                    <div><span>Lead score</span><strong>{r.lead_score ?? "—"}</strong></div>
                    <div><span>Traded F&amp;O</span><Answer value={r.traded_fno} /></div>
                    <div><span>Tried funded</span><Answer value={r.tried_funded} /></div>
                    <div><span>Easy navigation</span><Answer value={r.demo_easy_nav} /></div>
                    <div><span>Feels live</span><Answer value={r.demo_feels_live} /></div>
                    <div><span>Would pay after demo</span><Answer value={r.demo_would_pay} /></div>
                    <div><span>Account type</span><strong>{r.account_type || "—"}</strong></div>
                    {r.note && <div className="waitlist-person-note"><span>Note</span><strong>{r.note}</strong></div>}
                  </div>
                </details>
              ))}
            </div>
          )}
          {(page > 0 || hasNext) && (
            <div className="waitlist-pagination">
              <span>Showing {num(page * WAITLIST_PAGE_SIZE + 1)}–{num(page * WAITLIST_PAGE_SIZE + rows.length)}{total == null ? "" : ` of ${num(total)}`}</span>
              <button className="btn" type="button" disabled={page === 0} onClick={() => setPage((p) => p - 1)}>Previous</button>
              <button className="btn" type="button" disabled={!hasNext} onClick={() => setPage((p) => p + 1)}>Next</button>
            </div>
          )}
        </>
      )}
    </Card>
    </section>
  );
}

function Answer({ value }) {
  if (value == null) return "—";
  return <Chip tone={value ? "green" : "grey"}>{value ? "Yes" : "No"}</Chip>;
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
