import React, { useCallback, useEffect, useRef, useState } from "react";
import { rpc } from "../supabase.js";
import { useRpc } from "../lib/useRpc.js";
import { IconSearch, IconX } from "./icons.jsx";
import { Chip } from "./ui.jsx";
import { ago, dateOnly, num, provider, signedMoney } from "../lib/format.js";

/** What to call somebody when the database has an email, a name, or neither. */
export function userLabel(u) {
  if (!u) return "";
  return u.email || u.name || String(u.user_id ?? "").slice(0, 14) + "…";
}

/**
 * The user picker that lives in the header, next to the demo toggle.
 *
 * Search runs in the database rather than over a downloaded list: the panel
 * must not hold every user in memory to let somebody type four letters, and
 * the shortlist has to be ordered by who was here most recently — which is
 * the answer to "the person I am being asked about" nine times out of ten.
 *
 * An empty box is not an empty result. Opening the picker and seeing the last
 * twenty people to sign in is the fast path; typing is the fallback.
 */
export default function UserFilter({ value, onChange }) {
  const [open, setOpen] = useState(false);
  const [q, setQ] = useState("");
  const [rows, setRows] = useState([]);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState("");
  const [cursor, setCursor] = useState(0);

  const wrapRef = useRef(null);
  const inputRef = useRef(null);

  // Debounced, and every in-flight answer is checked against the query that is
  // current when it lands. Without that, a slow response to "ra" overwrites a
  // fast one to "ravi" and the list contradicts the box.
  useEffect(() => {
    if (!open) return;
    let alive = true;
    setLoading(true);
    const t = setTimeout(() => {
      rpc("admin_user_search", { p_q: q, p_limit: 20 })
        .then((d) => { if (alive) { setRows(d ?? []); setError(""); setCursor(0); } })
        .catch((e) => { if (alive) { setError(e.message); setRows([]); } })
        .finally(() => { if (alive) setLoading(false); });
    }, q ? 220 : 0);
    return () => { alive = false; clearTimeout(t); };
  }, [q, open]);

  // Click anywhere else, or press Escape, and the popover goes away.
  useEffect(() => {
    if (!open) return;
    const onDoc = (e) => { if (!wrapRef.current?.contains(e.target)) setOpen(false); };
    const onKey = (e) => { if (e.key === "Escape") setOpen(false); };
    document.addEventListener("mousedown", onDoc);
    document.addEventListener("keydown", onKey);
    return () => {
      document.removeEventListener("mousedown", onDoc);
      document.removeEventListener("keydown", onKey);
    };
  }, [open]);

  useEffect(() => { if (open) inputRef.current?.focus(); }, [open]);

  const pick = useCallback((u) => { onChange(u); setOpen(false); setQ(""); }, [onChange]);

  const onKeyDown = (e) => {
    if (e.key === "ArrowDown") { e.preventDefault(); setCursor((c) => Math.min(c + 1, rows.length - 1)); }
    else if (e.key === "ArrowUp") { e.preventDefault(); setCursor((c) => Math.max(c - 1, 0)); }
    else if (e.key === "Enter" && rows[cursor]) { e.preventDefault(); pick(rows[cursor]); }
  };

  return (
    <div className="userfilter" ref={wrapRef}>
      <button
        className={`btn picker ${value ? "on" : ""}`}
        onClick={() => setOpen((o) => !o)}
        title={value ? "Showing one person — click to change" : "Narrow the whole dashboard to one person"}
      >
        <IconSearch style={{ width: 14, height: 14 }} />
        <span className="picker-label">{value ? userLabel(value) : "All users"}</span>
      </button>

      {value && (
        <button
          className="btn picker-clear"
          onClick={() => onChange(null)}
          title="Back to everybody"
          aria-label="Clear the user filter"
        >
          <IconX style={{ width: 14, height: 14 }} />
        </button>
      )}

      {open && (
        <div className="pop" role="listbox">
          <div className="pop-search">
            <IconSearch style={{ width: 14, height: 14, color: "var(--text-mute)", flex: "0 0 14px" }} />
            <input
              ref={inputRef}
              value={q}
              onChange={(e) => setQ(e.target.value)}
              onKeyDown={onKeyDown}
              placeholder="Email, name or user id…"
            />
          </div>

          <div className="pop-list">
            <button
              className={`pop-item ${!value ? "picked" : ""}`}
              onClick={() => { onChange(null); setOpen(false); setQ(""); }}
            >
              <div className="pop-name">Everyone</div>
              <div className="pop-sub">Platform totals — how the dashboard normally reads</div>
            </button>

            {error && <div className="pop-msg err">{error}</div>}
            {!error && loading && <div className="pop-msg">Searching…</div>}
            {!error && !loading && rows.length === 0 && (
              <div className="pop-msg">
                {q ? <>Nobody matches “{q}”.</> : <>No users in the database yet.</>}
              </div>
            )}

            {!loading && rows.map((u, i) => (
              <button
                key={u.user_id}
                className={`pop-item ${i === cursor ? "cursor" : ""} ${value?.user_id === u.user_id ? "picked" : ""}`}
                onMouseEnter={() => setCursor(i)}
                onClick={() => pick(u)}
              >
                <div className="pop-name">{userLabel(u)}</div>
                <div className="pop-sub">
                  {u.name && u.email ? <>{u.name} · </> : null}
                  last seen {ago(u.last_seen)} · {num(u.logins)} sign-in{Number(u.logins) === 1 ? "" : "s"}
                  {Number(u.fills) > 0 ? <> · {num(u.fills)} trades</> : null}
                </div>
              </button>
            ))}
          </div>

          <div className="pop-foot">
            Newest first. Picking somebody narrows every page — tiles, charts and tables.
          </div>
        </div>
      )}
    </div>
  );
}

/**
 * The strip under the header, shown only while a filter is on.
 *
 * It exists for the thing this feature was actually asked for: being able to
 * point at a screen and say who it is about. A filtered dashboard that does
 * not say, loudly and permanently, whose numbers these are is worse than no
 * filter at all — every tile still looks like a platform total.
 *
 * The counts are re-read on refresh rather than frozen at the moment somebody
 * was picked, so "last seen" does not slowly become a lie while the tab is open.
 */
export function UserStrip({ user, onClear, refreshKey }) {
  const live = useRpc("admin_user_search", { p_q: user.user_id, p_limit: 1 }, [refreshKey]);
  const u = live.data?.[0] ?? user;

  return (
    <div className="userstrip">
      <div className="userstrip-main">
        <div className="userstrip-top">
          <span className="userstrip-eyebrow">Showing one person</span>
          <strong className="userstrip-name">{userLabel(u)}</strong>
          {u.name && u.email ? <span className="dim">{u.name}</span> : null}

          {u.is_tester && <Chip tone="violet">tester</Chip>}
          {u.account_type && <Chip tone={u.account_type === "live" ? "green" : "grey"}>{u.account_type}</Chip>}
          {u.converted_at && <Chip tone="green">paid</Chip>}
          {!u.converted_at && u.demo_started_at && <Chip tone="amber">demo only</Chip>}
          {u.country && <Chip>{u.country}</Chip>}
          {u.provider && <Chip>{provider(u.provider)}</Chip>}
        </div>

        <div className="userstrip-facts">
          <span>joined {dateOnly(u.created_at)}</span>
          <span>last seen {ago(u.last_seen)}</span>
          <span>{num(u.logins)} sign-in{Number(u.logins) === 1 ? "" : "s"}</span>
          <span>{num(u.fills)} trade{Number(u.fills) === 1 ? "" : "s"}</span>
          {Number(u.fills) > 0 && (
            <span className={Number(u.realized_pnl) > 0 ? "up-text" : Number(u.realized_pnl) < 0 ? "down-text" : ""}>
              {signedMoney(u.realized_pnl)} realised
            </span>
          )}
          <span className="mono dim">{u.user_id}</span>
        </div>
      </div>

      <button className="btn" onClick={onClear}>
        <IconX style={{ width: 14, height: 14 }} />
        Show everyone
      </button>
    </div>
  );
}
