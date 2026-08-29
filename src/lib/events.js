/**
 * The vocabulary of the activity feed, in one place.
 *
 * `kind` arrives from the database as a short machine word — `demo_start`,
 * `account_type` — and three surfaces now have to agree on what to call it:
 * the chip in the table, the Event filter above it, and the order that filter
 * lists its options in. When those three disagreed the dropdown offered
 * "demo_start" and the row underneath said "started demo", which reads as two
 * different things.
 *
 * Insertion order is the display order: it follows a life on the platform —
 * arrived, came back, tried the demo, paid — rather than the alphabet.
 */
export const KIND_META = {
  signup:       { tone: "green",  label: "new account" },
  login:        { tone: "blue",   label: "signed in" },
  demo_start:   { tone: "amber",  label: "started demo" },
  converted:    { tone: "violet", label: "paid" },
  account_type: { tone: "grey",   label: "type changed" },
  tester:       { tone: "violet", label: "tester granted" },
  settings:     { tone: "grey",   label: "settings saved" },
};

/** Unknown kinds show their raw name rather than vanishing — a new event type
 *  added to the trigger should be visible here the day it starts firing, not
 *  after somebody remembers to update this file. */
export function kindLabel(kind) {
  return KIND_META[kind]?.label ?? String(kind ?? "—");
}

export function kindTone(kind) {
  return KIND_META[kind]?.tone ?? "grey";
}

/** Sort key for a kind: known kinds in the order above, unknown ones after. */
export function kindRank(kind) {
  const i = Object.keys(KIND_META).indexOf(kind);
  return i === -1 ? 99 : i;
}


/* ------------------------------------------------------------- repeats -- */

/**
 * The feed arrives with the same event in it several times over.
 *
 * That is the trigger working as designed: `app_ensure_user` touches the users
 * row on every sign-in, and anything else in the app that touches it during
 * the same session touches it again — so one person arriving once can write
 * four `login` rows a few minutes apart. Drawn one per line, the log reads as
 * four visits, the newest twelve rows on the Overview card are one person
 * saying hello, and the Event filter counts a number nobody would recognise.
 *
 * So repeats of the same event by the same person, inside one session window,
 * are drawn as ONE row carrying `repeats: 4` — not dropped. A merged row keeps
 * the newest timestamp (the answer to "when were they last here"), remembers
 * the oldest in `first_at`, and the table prints ×4 beside the chip. Nothing
 * is hidden; it is counted instead of repeated.
 *
 * An hour is the window because it is the length of a session, not of a
 * sign-in: two visits either side of lunch stay two rows.
 */
export const REPEAT_WINDOW_MS = 60 * 60 * 1000;

/** A key that is unique per event, which the raw rows have no column for.
 *  Feed rows share `user_id` — using that as a React key made every row of a
 *  chatty account collide, and a collided key is why a filtered table could
 *  keep drawing rows the filter had already excluded. */
export function eventKey(r) {
  return `${r?.user_id ?? ""}|${r?.kind ?? ""}|${r?.at ?? ""}`;
}

const millis = (r) => {
  const t = Date.parse(r?.at ?? "");
  return Number.isFinite(t) ? t : null;
};

/**
 * Collapse runs of the same (person, event) into one row each.
 *
 * Newest first, and each repeat extends the window from the one before it, so
 * a burst of six sign-ins ninety seconds apart is one row however long the
 * burst ran. Rows whose timestamp will not parse are never merged — an unknown
 * time cannot be shown to be inside a window.
 */
export function collapseRepeats(rows, windowMs = REPEAT_WINDOW_MS) {
  if (!rows?.length) return [];

  const ordered = [...rows].sort((a, b) => (millis(b) ?? 0) - (millis(a) ?? 0));
  const open = new Map();   // "user|kind" -> the row still accepting repeats
  const out = [];

  for (const r of ordered) {
    const key = `${r.user_id ?? ""}|${r.kind ?? ""}`;
    const t = millis(r);
    const group = open.get(key);

    if (group && t !== null && group.at_ms !== null && group.at_ms - t <= windowMs) {
      group.repeats += 1;
      group.first_at = r.at;
      group.at_ms = t;        // chain the window forward from this repeat
      continue;
    }

    const row = { ...r, id: eventKey(r), repeats: 1, first_at: r.at, at_ms: t };
    open.set(key, row);
    out.push(row);
  }

  // at_ms was scaffolding for the window arithmetic; the rows that leave here
  // carry only the columns the feed actually draws, plus repeats / first_at.
  return out.map(({ at_ms, ...row }) => row);
}
