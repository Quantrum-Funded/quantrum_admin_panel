import React, { useCallback, useMemo, useState } from "react";
import { IconX } from "./icons.jsx";
import { Chip } from "./ui.jsx";
import { collapseRepeats, kindLabel, kindRank, kindTone } from "../lib/events.js";
import { dateTime, num } from "../lib/format.js";

/**
 * The filter strip that sits above an event feed: Event, User, Sort, Apply.
 *
 * It behaves the way the filter row in a spreadsheet does, which is what was
 * asked for: each dropdown offers only the values that are actually in the
 * rows on screen, with a count next to each, so picking one can never produce
 * an empty table by surprise. A value nobody has triggered is not offered at
 * all — an Event list padded out with seven kinds when the log only holds
 * sign-ins is a list you have to read before you can dismiss it.
 *
 * NOTHING HAPPENS UNTIL APPLY. Picking a dropdown edits a draft; the table
 * keeps showing the last applied filter until the button is pressed. That is
 * deliberate — the three controls are read as one question ("Amit's sign-ins,
 * oldest first"), and a table that re-sorted itself twice on the way to asking
 * it made the first two answers look like the answer.
 *
 * Filtering happens here in the browser, over the page of rows the RPC already
 * returned, which is why Apply is instant and why the count line says how big
 * that page is. The header's user picker is the other kind of filter — it goes
 * to the database and narrows the whole dashboard. Both exist on purpose: this
 * one answers "who is in this list", that one answers "show me this person".
 */

/** Sort runs through Apply with everything else, so the order and the rows it
 *  orders always change together, in one redraw. */
export const SORTS = [
  { value: "new",   label: "Newest first" },
  { value: "old",   label: "Oldest first" },
  { value: "user",  label: "User A–Z" },
  { value: "event", label: "Event type" },
];

const BLANK = { kind: "", who: "", sort: "new" };

/**
 * @param rows        what the feed RPC returned (null while loading)
 * @param cap         how many rows the card draws unfiltered; the filter still
 *                    searches the whole page, so a card that shows twelve can
 *                    find the one `paid` event among eighty.
 * @param capFiltered how many it draws once a filter is on. Higher on purpose:
 *                    somebody who has just asked for one person's events meant
 *                    all of them, not the newest twelve of them.
 */
export function useFeedFilter(rows, { cap = Infinity, capFiltered = cap } = {}) {
  const [draft, setDraft] = useState(BLANK);
  const [applied, setApplied] = useState(BLANK);

  // Repeats become one row with a count before anything else looks at them,
  // so the table, the dropdown counts and the count line all describe the same
  // list. See collapseRepeats() for why the feed repeats itself at all.
  const all = useMemo(() => collapseRepeats(rows), [rows]);

  const kinds = useMemo(
    () => tally(all, (r) => r.kind, (v) => kindLabel(v))
      .sort((a, b) => kindRank(a.value) - kindRank(b.value)),
    [all]
  );

  // People are listed alphabetically rather than by how busy they are: this
  // dropdown is used to find one known name, not to rank anybody.
  const people = useMemo(
    () => tally(all, (r) => r.user_id, (_v, r) => personLabel(r))
      .sort((a, b) => a.label.localeCompare(b.label)),
    [all]
  );

  // A refresh can retire a picked value — the person's last event scrolls off
  // the end of the page. Both the draft and the applied filter fall back to
  // "all" for a value that is no longer offered, so a select can never sit on
  // a value missing from its own list and the table can never be empty under
  // a name that is not in it.
  const live = (v, options) => (options.some((o) => o.value === v) ? v : "");
  const kind = live(applied.kind, kinds);
  const who  = live(applied.who,  people);
  const sort = applied.sort;

  const shown = { kind: live(draft.kind, kinds), who: live(draft.who, people), sort: draft.sort };

  const matched = useMemo(
    () => sortRows(all.filter((r) => (!kind || r.kind === kind) && (!who || r.user_id === who)), sort),
    [all, kind, who, sort]
  );

  const set   = useCallback((patch) => setDraft((d) => ({ ...d, ...patch })), []);
  const clear = useCallback(() => { setDraft(BLANK); setApplied(BLANK); }, []);
  // Applies what the dropdowns are SHOWING, not what state happens to hold: a
  // value the last refresh retired is already gone from the select, and it
  // must not come back into effect because Apply was pressed afterwards.
  const apply = () => setApplied(shown);

  const active = Boolean(kind || who) || sort !== BLANK.sort;
  const narrowed = Boolean(kind || who);

  return {
    rows: matched.slice(0, narrowed ? capFiltered : cap),  // what the table draws
    matched: matched.length,     // what the filter found
    total: all.length,           // rows the card has, repeats already merged
    raw: rows?.length ?? 0,      // rows the RPC returned, repeats and all
    kind, who, sort,             // what is applied
    draft: shown,                // what the dropdowns are showing
    set, apply, clear,
    dirty: shown.kind !== kind || shown.who !== who || shown.sort !== sort,
    kinds, people,
    active, narrowed,
  };
}

/** The strip itself. Render it directly above the table, inside a `pad={false}`
 *  card, so the filters and the columns they act on share one edge. */
export function FeedFilters({ f, hideUser = false }) {
  if (!f.total) return null;

  const showUser = !hideUser && f.people.length > 1;

  return (
    <div className="filterbar">
      <label className="filter">
        <span>Event</span>
        <select
          className="select"
          value={f.draft.kind}
          onChange={(e) => f.set({ kind: e.target.value })}
        >
          <option value="">All events ({num(f.total)})</option>
          {f.kinds.map((o) => (
            <option key={o.value} value={o.value}>{o.label} ({num(o.count)})</option>
          ))}
        </select>
      </label>

      {showUser && (
        <label className="filter">
          <span>User</span>
          <select
            className="select"
            value={f.draft.who}
            onChange={(e) => f.set({ who: e.target.value })}
          >
            <option value="">All users ({num(f.people.length)})</option>
            {f.people.map((o) => (
              <option key={o.value} value={o.value}>{o.label} ({num(o.count)})</option>
            ))}
          </select>
        </label>
      )}

      <label className="filter">
        <span>Sort</span>
        <select
          className="select"
          value={f.draft.sort}
          onChange={(e) => f.set({ sort: e.target.value })}
        >
          {SORTS.map((o) => (
            <option key={o.value} value={o.value}>{o.label}</option>
          ))}
        </select>
      </label>

      <button
        className={`btn sm ${f.dirty ? "primary" : ""}`}
        onClick={f.apply}
        disabled={!f.dirty}
        title={f.dirty ? "Apply these to the table below" : "The table already shows these"}
      >
        Apply
      </button>

      <div className="spacer" />

      <span className="filter-count">
        {countLine(f)}
        {f.dirty && <span className="filter-dirty"> · not applied yet</span>}
      </span>

      {f.active && (
        <button className="btn sm" onClick={f.clear} title="Show every event again, newest first">
          <IconX style={{ width: 13, height: 13 }} />
          Clear
        </button>
      )}
    </div>
  );
}

/**
 * One row's Event cell: the chip, plus ×4 when four of that event by that
 * person were merged into this row. The count is a plain number rather than a
 * second chip so the column still scans as one chip per line.
 */
export function EventCell({ row }) {
  return (
    <span className="eventcell">
      <Chip tone={kindTone(row.kind)}>{kindLabel(row.kind)}</Chip>
      {row.repeats > 1 && (
        <span
          className="repeat"
          title={`${row.repeats} × ${kindLabel(row.kind)} between ${dateTime(row.first_at)} and ${dateTime(row.at)} — shown as one row`}
        >
          ×{row.repeats}
        </span>
      )}
    </span>
  );
}

/* Sorting is applied AFTER filtering, over the matches only, so "oldest first"
   means the oldest match rather than the oldest row that was fetched. The
   secondary key is always time: two rows that tie on user or on event still
   come back in a stable, readable order rather than in whatever order the
   filter happened to walk them. */
function sortRows(rows, sort) {
  const t = (r) => Date.parse(r.at ?? "") || 0;
  const newest = (a, b) => t(b) - t(a);

  if (sort === "old")   return [...rows].sort((a, b) => t(a) - t(b));
  if (sort === "user")  return [...rows].sort((a, b) =>
    personLabel(a).localeCompare(personLabel(b)) || newest(a, b));
  if (sort === "event") return [...rows].sort((a, b) =>
    kindRank(a.kind) - kindRank(b.kind) || newest(a, b));
  return [...rows].sort(newest);
}

/* Says which of three things is on screen — a slice of the matches, all the
   matches, or simply everything — because "12 events" under a filter is the
   kind of number somebody screenshots and misreads. Merged repeats are named
   here too: a card that quietly turned 80 rows into 23 owes an explanation. */
function countLine(f) {
  const capped = f.rows.length < f.matched;
  const base =
    f.narrowed && capped ? `${num(f.rows.length)} of ${num(f.matched)} matching` :
    f.narrowed           ? `${num(f.matched)} of ${num(f.total)} loaded` :
    capped               ? `newest ${num(f.rows.length)} of ${num(f.total)} loaded` :
                           `${num(f.total)} event${f.total === 1 ? "" : "s"}`;

  const merged = f.raw - f.total;
  return merged > 0
    ? `${base} · ${num(merged)} repeat${merged === 1 ? "" : "s"} merged`
    : base;
}

/** What to call somebody in a dropdown: the same fallback chain the table
 *  column uses, so a row and its filter option read identically. */
function personLabel(r) {
  return r.email || r.name || String(r.user_id ?? "").slice(0, 14) + "…";
}

/** Distinct values of one column, each with how many rows carry it. Blanks are
 *  skipped: "" is not a choice anybody means to make. */
function tally(rows, valueOf, labelOf) {
  const seen = new Map();
  for (const r of rows) {
    const v = valueOf(r);
    if (v === null || v === undefined || v === "") continue;
    const hit = seen.get(v);
    if (hit) hit.count += 1;
    else seen.set(v, { value: v, label: labelOf(v, r), count: 1 });
  }
  return [...seen.values()];
}

/** Shown in place of the table when the filters match nothing. It names what
 *  was asked for: an empty table under three dropdowns is otherwise indis-
 *  tinguishable from a database with nothing in it. */
export function noMatch(f) {
  const who = f.who ? f.people.find((p) => p.value === f.who)?.label : null;
  return (
    <>
      No <strong>{kindLabel(f.kind) || "matching"}</strong> event
      {who ? <> for <strong>{who}</strong></> : null} among the ones loaded on
      this card. <em>Clear</em> puts them all back.
    </>
  );
}
