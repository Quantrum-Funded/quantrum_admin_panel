import React, { useEffect, useMemo, useState } from "react";
import { rpc } from "../supabase.js";
import { AreaTrend, C, Donut, Legend } from "../components/charts.jsx";
import { Card, Chip, Empty, Loading, Stat } from "../components/ui.jsx";
import { dateTime, num } from "../lib/format.js";

const BATCH_SIZE = 100; // admin_waitlist_leads caps each request at 100.
const PAGE_SIZE = 25;
const DAY_MS = 86400000;
const dayParts = new Intl.DateTimeFormat("en-GB", {
  timeZone: "Asia/Kolkata", year: "numeric", month: "2-digit", day: "2-digit",
});

function istDay(value) {
  const parts = Object.fromEntries(dayParts.formatToParts(new Date(value)).map((p) => [p.type, p.value]));
  return `${parts.year}-${parts.month}-${parts.day}`;
}

function options(rows, key) {
  return [...new Set(rows.map((row) => row[key]).filter(Boolean))].sort((a, b) => a.localeCompare(b));
}

function distribution(rows, key) {
  const counts = new Map();
  rows.forEach((row) => {
    const label = row[key] || "Unspecified";
    counts.set(label, (counts.get(label) || 0) + 1);
  });
  return [...counts].map(([name, value]) => ({ name, value })).sort((a, b) => b.value - a.value);
}

export default function Waitlist({ days, refreshKey }) {
  const [leads, setLeads] = useState([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState("");
  const [loaded, setLoaded] = useState(0);
  const [query, setQuery] = useState("");
  const [category, setCategory] = useState("");
  const [tier, setTier] = useState("");
  const [pay, setPay] = useState("");
  const [page, setPage] = useState(0);

  useEffect(() => {
    let alive = true;
    setLoading(true);
    setError("");
    setLoaded(0);
    setPage(0);
    (async () => {
      const all = [];
      for (let offset = 0; ; offset += BATCH_SIZE) {
        const batch = await rpc("admin_waitlist_leads", { p_limit: BATCH_SIZE, p_offset: offset });
        all.push(...batch);
        if (alive) setLoaded(all.length);
        if (batch.length < BATCH_SIZE) break;
      }
      if (alive) setLeads(all);
    })().catch((e) => { if (alive) setError(e.message); })
      .finally(() => { if (alive) setLoading(false); });
    return () => { alive = false; };
  }, [refreshKey]);

  const categories = useMemo(() => options(leads, "interest_category"), [leads]);
  const tiers = useMemo(() => options(leads, "interest_tier"), [leads]);
  const filtered = useMemo(() => {
    const needle = query.trim().toLocaleLowerCase();
    return leads.filter((row) =>
      (!needle || [row.name, row.email, row.phone].some((value) => String(value || "").toLocaleLowerCase().includes(needle))) &&
      (!category || row.interest_category === category) &&
      (!tier || row.interest_tier === tier) &&
      (!pay || (pay === "yes" ? row.would_pay_fee === true : pay === "no" ? row.would_pay_fee === false : row.would_pay_fee == null))
    );
  }, [leads, query, category, tier, pay]);

  const active = Boolean(query.trim() || category || tier || pay);
  const now = Date.now();
  const lastSeven = filtered.filter((row) => row.created_at && new Date(row.created_at).getTime() >= now - 7 * DAY_MS).length;
  const willing = filtered.filter((row) => row.would_pay_fee === true).length;
  const traded = filtered.filter((row) => row.traded_fno === true).length;
  const daily = Array.from({ length: days }, (_, i) => {
    const d = new Date(now - (days - 1 - i) * DAY_MS);
    return { day: istDay(d), signups: 0 };
  });
  const byDay = new Map(daily.map((d) => [d.day, d]));
  filtered.forEach((row) => {
    if (!row.created_at) return;
    const day = istDay(row.created_at);
    if (byDay.has(day)) byDay.get(day).signups += 1;
  });
  const categoryData = distribution(filtered, "interest_category");
  const tierData = distribution(filtered, "interest_tier");
  const shown = filtered.slice(page * PAGE_SIZE, (page + 1) * PAGE_SIZE);

  function change(setter) {
    return (event) => { setter(event.target.value); setPage(0); };
  }

  if (error) return <div className="alert err">Could not load waitlist details. {error}</div>;
  if (loading) return <div className="waitlist-page"><div className="dim">Loading waitlist{loaded ? ` · ${num(loaded)} people read` : "…"}</div><Loading rows={4} height={100} /></div>;

  return (
    <div className="waitlist-page">
      <div className="grid k4">
        <Stat label={active ? "Matching people" : "Total waitlist"} value={num(filtered.length)} foot={active ? `${num(leads.length)} people in all` : "All time"} />
        <Stat label="Added this week" value={num(lastSeven)} tone="info" foot="Last 7 days" />
        <Stat label="Would pay" value={num(willing)} tone="up" foot={filtered.length ? `${Math.round(willing / filtered.length * 100)}% of shown people` : "No people shown"} />
        <Stat label="Traded F&O" value={num(traded)} tone="violet" foot={filtered.length ? `${Math.round(traded / filtered.length * 100)}% of shown people` : "No people shown"} />
      </div>

      <Card title="Find people" note="Filters update the numbers, charts and list together">
        <div className="waitlist-filters">
          <label>Search name, email or phone<input className="input" type="search" value={query} onChange={change(setQuery)} placeholder="Search people" /></label>
          <label>Interest<select className="select" value={category} onChange={change(setCategory)}><option value="">All interests</option>{categories.map((value) => <option key={value} value={value}>{value}</option>)}</select></label>
          <label>Tier<select className="select" value={tier} onChange={change(setTier)}><option value="">All tiers</option>{tiers.map((value) => <option key={value} value={value}>{value}</option>)}</select></label>
          <label>Would pay<select className="select" value={pay} onChange={change(setPay)}><option value="">Any answer</option><option value="yes">Yes</option><option value="no">No</option><option value="unknown">Not answered</option></select></label>
          {active && <button type="button" className="btn" onClick={() => { setQuery(""); setCategory(""); setTier(""); setPay(""); setPage(0); }}>Clear filters</button>}
        </div>
      </Card>

      <div className="grid wide-left">
        <Card title="Waitlist growth" note={`People added per day · last ${days} days · IST`}>
          {filtered.length ? <AreaTrend data={daily} series={[{ key: "signups", label: "Added", color: C.accent }]} /> : <Empty title="No people to chart">Try clearing the filters.</Empty>}
        </Card>
        <Card title="Interest" note="What people want">
          {categoryData.length ? <><Donut data={categoryData} nameKey="name" valueKey="value" /><Legend data={categoryData} nameKey="name" valueKey="value" /></> : <Empty title="No interests to chart">Try clearing the filters.</Empty>}
        </Card>
      </div>

      <Card title="Preferred tier" note="Answers from people shown">
        {tierData.length ? <><Donut data={tierData} nameKey="name" valueKey="value" /><Legend data={tierData} nameKey="name" valueKey="value" /></> : <Empty title="No tiers to chart">Try clearing the filters.</Empty>}
      </Card>

      <Card title="Waitlist people" note={`Newest first · ${num(filtered.length)} shown${active ? ` of ${num(leads.length)}` : ""} · select a person to see their answers`} pad={false}>
        {shown.length === 0 ? <Empty title={active ? "No people match" : "No waitlist entries yet"}>{active ? "Try changing the filters." : "New waitlist signups will appear here."}</Empty> : (
          <div className="waitlist-list">
            <div className="waitlist-list-head" aria-hidden="true"><span>Person</span><span>Interest</span><span>Would pay</span><span>Added</span><span /></div>
            {shown.map((row) => <Person key={row.id} row={row} />)}
          </div>
        )}
        {filtered.length > PAGE_SIZE && <div className="waitlist-pagination">
          <span>Showing {num(page * PAGE_SIZE + 1)}–{num(page * PAGE_SIZE + shown.length)} of {num(filtered.length)}</span>
          <button type="button" className="btn" disabled={page === 0} onClick={() => setPage((p) => p - 1)}>Previous</button>
          <button type="button" className="btn" disabled={(page + 1) * PAGE_SIZE >= filtered.length} onClick={() => setPage((p) => p + 1)}>Next</button>
        </div>}
      </Card>
    </div>
  );
}

function Answer({ value }) {
  return value == null ? "—" : <Chip tone={value ? "green" : "grey"}>{value ? "Yes" : "No"}</Chip>;
}

function Person({ row: r }) {
  return <details className="waitlist-person">
    <summary className="waitlist-person-summary">
      <span className="waitlist-person-contact"><strong>{r.name || r.email || r.phone || "Unnamed lead"}</strong><span>{[r.email && r.name ? r.email : null, r.phone].filter(Boolean).join(" · ") || "No contact details"}</span></span>
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
  </details>;
}
