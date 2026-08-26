import React from "react";
import {
  ResponsiveContainer, AreaChart, Area, BarChart, Bar, LineChart, Line,
  XAxis, YAxis, CartesianGrid, Tooltip, PieChart, Pie, Cell,
} from "recharts";
import { shortDay, num, money } from "../lib/format.js";

const GRID = "#e9dece";

/* One palette, used everywhere, so a colour means the same thing on every
   chart in the app. Retuned for a white card: these are the paper-side
   values, each ≥ 3:1 against #fff so a thin 2px series line is still legible.
   The brand orange stays the first series — it is the one saturated note the
   design allows, and a chart is where it earns its keep. */
export const C = {
  accent: "#fa4f0c",  /* brand orange — the primary series */
  cyan:   "#3a5a7d",  /* --info, muted navy */
  green:  "#2f6b4a",  /* --up */
  red:    "#9b2c2c",  /* --down, oxblood */
  amber:  "#96631a",  /* --warn */
  violet: "#7a4a63",  /* plum, for a second brand-adjacent series */
  slate:  "#8a7565",  /* taupe — the "everything else" bucket */
};

export const PIE_COLORS = [C.accent, C.cyan, C.green, C.amber, C.violet, C.red, C.slate];

function Tip({ active, payload, label, fmt }) {
  if (!active || !payload?.length) return null;
  return (
    <div className="chart-tip">
      <div className="t-day">{shortDay(label)}</div>
      {payload.map((p) => (
        <div className="t-row" key={p.dataKey}>
          <span className="t-sw" style={{ background: p.color || p.fill }} />
          {p.name}: <strong style={{ color: "var(--text)" }}>
            {fmt ? fmt(p.value, p.dataKey) : num(p.value)}
          </strong>
        </div>
      ))}
    </div>
  );
}

const axis = { stroke: GRID, tickLine: false, axisLine: false };

/** Stacked/overlaid area — the default for "activity over time". */
export function AreaTrend({ data, series, height = 230, fmt }) {
  return (
    <ResponsiveContainer width="100%" height={height}>
      <AreaChart data={data} margin={{ top: 6, right: 6, left: -18, bottom: 0 }}>
        <defs>
          {series.map((s) => (
            <linearGradient key={s.key} id={`g-${s.key}`} x1="0" y1="0" x2="0" y2="1">
              <stop offset="0%" stopColor={s.color} stopOpacity={0.34} />
              <stop offset="100%" stopColor={s.color} stopOpacity={0.02} />
            </linearGradient>
          ))}
        </defs>
        <CartesianGrid stroke={GRID} strokeDasharray="3 3" vertical={false} />
        <XAxis dataKey="day" tickFormatter={shortDay} minTickGap={26} {...axis} />
        <YAxis width={54} allowDecimals={false} {...axis} />
        <Tooltip content={<Tip fmt={fmt} />} cursor={{ stroke: GRID }} />
        {series.map((s) => (
          <Area
            key={s.key}
            type="monotone"
            dataKey={s.key}
            name={s.label}
            stroke={s.color}
            strokeWidth={2}
            fill={`url(#g-${s.key})`}
            isAnimationActive={false}
          />
        ))}
      </AreaChart>
    </ResponsiveContainer>
  );
}

export function BarTrend({ data, series, height = 230, fmt }) {
  return (
    <ResponsiveContainer width="100%" height={height}>
      <BarChart data={data} margin={{ top: 6, right: 6, left: -18, bottom: 0 }}>
        <CartesianGrid stroke={GRID} strokeDasharray="3 3" vertical={false} />
        <XAxis dataKey="day" tickFormatter={shortDay} minTickGap={26} {...axis} />
        <YAxis width={54} allowDecimals={false} {...axis} />
        <Tooltip content={<Tip fmt={fmt} />} cursor={{ fill: "rgba(43,30,23,.05)" }} />
        {series.map((s) => (
          <Bar key={s.key} dataKey={s.key} name={s.label} fill={s.color}
               radius={[3, 3, 0, 0]} isAnimationActive={false} />
        ))}
      </BarChart>
    </ResponsiveContainer>
  );
}

/** P&L over time — bars coloured by sign, because a loss should look like one. */
export function PnlTrend({ data, height = 230 }) {
  return (
    <ResponsiveContainer width="100%" height={height}>
      <BarChart data={data} margin={{ top: 6, right: 6, left: -6, bottom: 0 }}>
        <CartesianGrid stroke={GRID} strokeDasharray="3 3" vertical={false} />
        <XAxis dataKey="day" tickFormatter={shortDay} minTickGap={26} {...axis} />
        <YAxis width={68} tickFormatter={(v) => money(v, { compact: true })} {...axis} />
        <Tooltip content={<Tip fmt={(v) => money(v)} />} cursor={{ fill: "rgba(43,30,23,.05)" }} />
        <Bar dataKey="realized_pnl" name="Realised P&L" radius={[3, 3, 0, 0]} isAnimationActive={false}>
          {data.map((d, i) => (
            <Cell key={i} fill={Number(d.realized_pnl) >= 0 ? C.green : C.red} />
          ))}
        </Bar>
      </BarChart>
    </ResponsiveContainer>
  );
}

export function LineTrend({ data, series, height = 230, fmt }) {
  return (
    <ResponsiveContainer width="100%" height={height}>
      <LineChart data={data} margin={{ top: 6, right: 6, left: -18, bottom: 0 }}>
        <CartesianGrid stroke={GRID} strokeDasharray="3 3" vertical={false} />
        <XAxis dataKey="day" tickFormatter={shortDay} minTickGap={26} {...axis} />
        <YAxis width={54} allowDecimals={false} {...axis} />
        <Tooltip content={<Tip fmt={fmt} />} cursor={{ stroke: GRID }} />
        {series.map((s) => (
          <Line key={s.key} type="monotone" dataKey={s.key} name={s.label}
                stroke={s.color} strokeWidth={2} dot={false} isAnimationActive={false} />
        ))}
      </LineChart>
    </ResponsiveContainer>
  );
}

export function Donut({ data, nameKey, valueKey, height = 210 }) {
  const total = data.reduce((a, d) => a + Number(d[valueKey] || 0), 0);
  return (
    <div style={{ position: "relative" }}>
      <ResponsiveContainer width="100%" height={height}>
        <PieChart>
          <Pie
            data={data} dataKey={valueKey} nameKey={nameKey}
            innerRadius="58%" outerRadius="85%" paddingAngle={2} stroke="none"
            isAnimationActive={false}
          >
            {data.map((_, i) => <Cell key={i} fill={PIE_COLORS[i % PIE_COLORS.length]} />)}
          </Pie>
          <Tooltip
            content={({ active, payload }) =>
              active && payload?.length ? (
                <div className="chart-tip">
                  <div className="t-row">
                    <span className="t-sw" style={{ background: payload[0].payload.fill }} />
                    {payload[0].name}: <strong style={{ color: "var(--text)" }}>{num(payload[0].value)}</strong>
                  </div>
                </div>
              ) : null
            }
          />
        </PieChart>
      </ResponsiveContainer>
      <div style={{
        position: "absolute", inset: 0, display: "grid", placeItems: "center",
        pointerEvents: "none",
      }}>
        <div style={{ textAlign: "center" }}>
          <div className="num" style={{ fontSize: 22, fontWeight: 650 }}>{num(total)}</div>
          <div style={{ fontSize: 11, color: "var(--text-mute)" }}>total</div>
        </div>
      </div>
    </div>
  );
}

/** Legend that sits under a donut. Recharts' own is hard to theme. */
export function Legend({ data, nameKey, valueKey }) {
  return (
    <div style={{ display: "flex", flexWrap: "wrap", gap: "6px 14px", marginTop: 10 }}>
      {data.map((d, i) => (
        <div key={i} style={{ display: "flex", alignItems: "center", gap: 6, fontSize: 12 }}>
          <span className="t-sw" style={{
            width: 8, height: 8, borderRadius: 2,
            background: PIE_COLORS[i % PIE_COLORS.length],
          }} />
          <span style={{ color: "var(--text-dim)" }}>{d[nameKey]}</span>
          <span className="num" style={{ color: "var(--text)" }}>{num(d[valueKey])}</span>
        </div>
      ))}
    </div>
  );
}
