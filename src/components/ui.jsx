import React from "react";

export function Card({ title, note, right, children, pad = true }) {
  return (
    <div className="card">
      {(title || right) && (
        <div className="card-head">
          <div style={{ minWidth: 0 }}>
            {title && <div className="card-title">{title}</div>}
            {note && <div className="card-note">{note}</div>}
          </div>
          <div className="spacer" />
          {right}
        </div>
      )}
      <div className={pad ? "card-body" : ""}>{children}</div>
    </div>
  );
}

export function Stat({ label, value, foot, tone = "", live = false }) {
  return (
    <div className="card">
      <div className="stat">
        <div className="stat-label">
          <span className={`stat-dot ${tone} ${live ? "pulse" : ""}`} />
          {label}
        </div>
        <div className={`stat-value num ${tone === "up" ? "up-text" : tone === "down" ? "down-text" : ""}`}>
          {value}
        </div>
        {foot && <div className="stat-foot">{foot}</div>}
      </div>
    </div>
  );
}

export function Chip({ children, tone = "" }) {
  return <span className={`chip ${tone}`}>{children}</span>;
}

/** Colour-codes the values the schema actually uses, so the team reads status
 *  at a glance instead of parsing words. */
export function StatusChip({ value }) {
  const v = String(value ?? "").toUpperCase();
  const tone =
    v === "FILLED" || v === "CAPTURED" || v === "PASSED" || v === "COMPLETED" ? "green" :
    v === "REJECTED" || v === "FAILED" ? "red" :
    v === "OPEN" || v === "ACTIVE" ? "blue" :
    v === "CANCELLED" || v === "EXPIRED" ? "grey" :
    v === "PENDING" || v === "CREATED" || v === "AUTHORIZED" ? "amber" : "";
  return <Chip tone={tone}>{value || "—"}</Chip>;
}

export function Empty({ title, children }) {
  return (
    <div className="empty">
      <strong>{title}</strong>
      {children}
    </div>
  );
}

export function Loading({ rows = 4, height = 62 }) {
  return (
    <div style={{ display: "grid", gap: 10 }}>
      {Array.from({ length: rows }).map((_, i) => (
        <div key={i} className="skeleton" style={{ height }} />
      ))}
    </div>
  );
}

export function Table({ columns, rows, onRowClick, empty, emptyTitle = "Nothing here yet" }) {
  if (!rows || rows.length === 0) {
    return <Empty title={emptyTitle}>{empty}</Empty>;
  }
  return (
    <div className="table-wrap">
      <table>
        <thead>
          <tr>
            {columns.map((c) => (
              <th key={c.key} className={c.align === "right" ? "r" : ""}>{c.label}</th>
            ))}
          </tr>
        </thead>
        <tbody>
          {rows.map((row, i) => (
            <tr
              key={row.id ?? row.user_id ?? i}
              className={onRowClick ? "clickable" : ""}
              onClick={onRowClick ? () => onRowClick(row) : undefined}
            >
              {columns.map((c) => (
                <td
                  key={c.key}
                  className={[c.align === "right" ? "r num" : "", c.strong ? "strong" : ""].join(" ")}
                >
                  {c.render ? c.render(row) : row[c.key] ?? "—"}
                </td>
              ))}
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}

/** Segmented control — the 7d / 30d / 90d switch. */
export function Segmented({ value, onChange, options }) {
  return (
    <div className="seg">
      {options.map((o) => (
        <button
          key={o.value}
          className={value === o.value ? "on" : ""}
          onClick={() => onChange(o.value)}
        >
          {o.label}
        </button>
      ))}
    </div>
  );
}
