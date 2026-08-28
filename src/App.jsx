import React, { useCallback, useEffect, useState } from "react";
import { supabase, configured, rpc } from "./supabase.js";
import Login from "./components/Login.jsx";
import {
  IconGrid, IconActivity, IconChart, IconFunnel, IconRefresh, IconLogout,
} from "./components/icons.jsx";
import { Wordmark, LogoMark } from "./components/Logo.jsx";
import { Segmented } from "./components/ui.jsx";
import UserFilter, { UserStrip } from "./components/UserFilter.jsx";
import Overview from "./pages/Overview.jsx";
import Activity from "./pages/Activity.jsx";
import Trading from "./pages/Trading.jsx";
import Funnel from "./pages/Funnel.jsx";

const PAGES = [
  { key: "overview", label: "Overview",  icon: IconGrid,     title: "Overview",            sub: "Everything at a glance" },
  { key: "activity", label: "Logins",    icon: IconActivity, title: "Logins & activity",   sub: "Who signed in, and when" },
  { key: "trading",  label: "Trading",   icon: IconChart,    title: "Trading",             sub: "Orders, P&L and live exposure" },
  { key: "funnel",   label: "Funnel",    icon: IconFunnel,   title: "Signup funnel",       sub: "Sign up to paid, step by step" },
];

export default function App() {
  const [session, setSession] = useState(undefined); // undefined = still checking
  const [me, setMe] = useState(null);
  const [meErr, setMeErr] = useState(null);  // { message, kind }
  const [page, setPage] = useState("overview");

  // Demo accounts are excluded from money everywhere by default — the demo
  // seeds six fabricated P&L days per trial that nobody traded. This toggle is
  // how an operator deliberately looks at them, and it is deliberately global
  // so a number can never mean one thing on one card and another elsewhere.
  const [includeDemo, setIncludeDemo] = useState(false);
  const [days, setDays] = useState(30);

  // The third global filter: one person, or nobody in particular. Global for
  // the same reason the demo toggle is — a number that meant "this trader" on
  // one page and "the platform" on the next would be worse than no filter.
  // Null is everybody, which is what every page did before this existed.
  const [user, setUser] = useState(null);
  const [refreshKey, setRefreshKey] = useState(0);

  useEffect(() => {
    if (!configured) { setSession(null); return; }
    supabase.auth.getSession().then(({ data }) => setSession(data.session ?? null));
    const { data: sub } = supabase.auth.onAuthStateChange((_e, s) => setSession(s ?? null));
    return () => sub.subscription.unsubscribe();
  }, []);

  // Signed in is not the same as allowed in. Ask the database which it is.
  useEffect(() => {
    if (!session) { setMe(null); setMeErr(null); return; }
    let alive = true;
    rpc("admin_whoami")
      .then((r) => { if (alive) { setMe(r); setMeErr(null); } })
      .catch((e) => { if (alive) setMeErr({ message: e.message, kind: e.kind, detail: e.detail }); });
    return () => { alive = false; };
  }, [session]);

  const refresh = useCallback(() => setRefreshKey((k) => k + 1), []);

  if (session === undefined) {
    return <div className="login-wrap"><div className="dim">Loading…</div></div>;
  }
  if (!session) return <Login />;

  // The database has not been prepared yet. Nothing to do with this account —
  // showing the allow-list SQL here would send someone to fix the wrong thing.
  if (meErr?.kind === "setup") {
    return (
      <div className="login-wrap">
        <div className="login-card" style={{ maxWidth: 470 }}>
          <LogoMark size={34} title="Quantrum" />
          <h2 style={{ marginTop: 14 }}>One setup step left</h2>
          <p className="sub">Signed in fine as {session.user.email}.</p>

          <div className="alert info">
            {meErr.message}
            {meErr.detail && (
              <div className="mono" style={{ marginTop: 6, opacity: .8, overflowWrap: "anywhere" }}>
                {meErr.detail}
              </div>
            )}
          </div>

          <p style={{ fontSize: 13, color: "var(--text-dim)", margin: "0 0 10px" }}>
            The dashboard reads through functions that live in the database.
            In the Supabase dashboard open <strong>SQL Editor</strong> and run
            these, top to bottom. Each is a few KB and safe to re-run:
          </p>

          <ol style={{ fontSize: 12.5, color: "var(--text)", paddingLeft: 20, margin: "0 0 10px" }}>
            {[
              ["01_admin_foundation.sql", "tables, trigger, backfill"],
              ["02a_read_core.sql", "Overview"],
              ["02b_activity.sql", "the sign-in feed"],
              ["02c_trading.sql", "Trading + Funnel"],
              ["04_user_filter.sql", "the user picker in the header"],
            ].map(([file, what]) => (
              <li key={file} style={{ marginBottom: 5 }}>
                <span className="mono">{file}</span>
                <span style={{ color: "var(--text-mute)" }}> — {what}</span>
              </li>
            ))}
          </ol>

          <p style={{ fontSize: 11.5, color: "var(--text-mute)", margin: "0 0 14px" }}>
            Not sure which already ran? <span className="mono">00_check.sql</span>{" "}
            prints exactly what is installed and what is missing. There is also a
            single <span className="mono">RUN_THIS.sql</span>, but at ~50 KB a paste
            that long can truncate silently — which is what the small files avoid.
          </p>

          <p style={{ fontSize: 13, color: "var(--text-dim)", margin: "0 0 8px" }}>
            Then put this account on the allow-list:
          </p>
          <div className="mono" style={{
            color: "var(--text-dim)", background: "var(--surface-2)",
            border: "1px solid var(--border)", borderRadius: 9,
            padding: "9px 11px", marginBottom: 16, lineHeight: 1.6,
          }}>
            insert into public.admin_users (user_id, email, role)<br />
            select id, email, 'owner' from auth.users<br />
            where email = '{session.user.email}';
          </div>

          <div style={{ display: "flex", gap: 8 }}>
            <button className="btn primary" style={{ flex: 1 }} onClick={() => window.location.reload()}>
              I have run it — retry
            </button>
            <button className="btn" onClick={() => supabase.auth.signOut()}>
              Sign out
            </button>
          </div>
        </div>
      </div>
    );
  }

  if (meErr || (me && !me.is_admin)) {
    return (
      <div className="login-wrap">
        <div className="login-card">
          <LogoMark size={34} title="Quantrum" />
          <h2 style={{ marginTop: 14 }}>No access</h2>
          <p className="sub">Signed in as {session.user.email}</p>
          <div className="alert err">
            {meErr?.message || "This account is not on the admin allow-list."}
          </div>
          <div className="tip" style={{ marginBottom: 16 }}>
            An owner adds you by running, in the Supabase SQL editor:
            <div className="mono" style={{ marginTop: 6, color: "var(--text-dim)" }}>
              insert into public.admin_users (user_id, email, role)<br />
              select id, email, 'viewer' from auth.users<br />
              where email = '{session.user.email}';
            </div>
          </div>
          <div style={{ display: "flex", gap: 8 }}>
            <button className="btn primary" style={{ flex: 1 }} onClick={() => window.location.reload()}>
              Retry
            </button>
            <button className="btn" onClick={() => supabase.auth.signOut()}>
              Sign out
            </button>
          </div>
        </div>
      </div>
    );
  }
  if (!me) {
    return <div className="login-wrap"><div className="dim">Checking access…</div></div>;
  }

  const current = PAGES.find((p) => p.key === page) ?? PAGES[0];
  const shared = { days, includeDemo, refreshKey, userId: user?.user_id ?? null };

  return (
    <div className="shell">
      <aside className="sidebar">
        <div className="brand">
          <Wordmark size={30} sub="Admin dashboard" />
        </div>

        <div className="nav-label">Dashboard</div>
        {PAGES.map((p) => {
          const Icon = p.icon;
          return (
            <button
              key={p.key}
              className={`nav-item ${page === p.key ? "active" : ""}`}
              onClick={() => setPage(p.key)}
            >
              <Icon />
              {p.label}
            </button>
          );
        })}

        <div className="sidebar-foot">
          <div className="who">
            <div className="who-email">{me.email || session.user.email}</div>
            <div className="who-role">{me.role || "viewer"} · read-only</div>
          </div>
          <button className="nav-item" onClick={() => supabase.auth.signOut()}>
            <IconLogout />
            Sign out
          </button>
        </div>
      </aside>

      <div className="main">
        <header className="topbar">
          <div>
            <h1>{current.title}</h1>
            <div className="topbar-sub">{current.sub}</div>
          </div>
          <div className="spacer" />

          <UserFilter value={user} onChange={setUser} />

          <label className="toggle" title="The demo seeds fabricated P&L days that nobody traded. Off by default.">
            <input
              type="checkbox"
              checked={includeDemo}
              onChange={(e) => setIncludeDemo(e.target.checked)}
            />
            Include demo accounts
          </label>

          <Segmented
            value={days}
            onChange={setDays}
            options={[
              { value: 7,  label: "7d" },
              { value: 30, label: "30d" },
              { value: 90, label: "90d" },
            ]}
          />

          <button className="btn" onClick={refresh} title="Reload from the database">
            <IconRefresh style={{ width: 15, height: 15, verticalAlign: "-2px" }} />
          </button>
        </header>

        <main className="content">
          {user && (
            <UserStrip user={user} refreshKey={refreshKey} onClear={() => setUser(null)} />
          )}

          {page === "overview" && <Overview {...shared} />}
          {page === "activity" && <Activity {...shared} />}
          {page === "trading"  && <Trading {...shared} />}
          {page === "funnel"   && <Funnel {...shared} />}
        </main>
      </div>
    </div>
  );
}
