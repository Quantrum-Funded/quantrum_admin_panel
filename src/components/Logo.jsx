import React, { useId } from "react";

/**
 * The Quantrum mark, redrawn as real vector geometry.
 *
 * The trading app ships it as theme-paired PNGs (public/darkmode.png for dark
 * surfaces, lightmode.png for light) at ~250 KB each, which go soft when
 * scaled. The mark is four circular arcs and one diagonal bar, so it is drawn
 * here instead: a few hundred bytes, crisp at any size, and the ring follows
 * `currentColor` so one component serves the sidebar, the login card and the
 * favicon.
 *
 * Three details carry the likeness:
 *
 *   - The ring is broken by four gaps on the axes (12/3/6/9 o'clock). That is
 *     stroke-dasharray on a plain circle, not four hand-plotted arc paths —
 *     one dash+gap cycle is exactly a quarter of the circumference, so the
 *     gaps land on the axes with no fudge factor.
 *   - The tail of the Q crosses the lower right in brand orange, starting
 *     inside the ring's hole and ending well beyond its outer edge.
 *   - The ring is *cut* where the tail crosses rather than merely overlaid, so
 *     the orange sits in a clean channel. That is the mask below.
 */
export function LogoMark({ size = 32, className = "", title }) {
  // Unique per instance: two marks on one page must not share a mask id.
  const maskId = useId();

  return (
    <svg
      width={size}
      height={size}
      viewBox="0 0 100 100"
      fill="none"
      className={className}
      role={title ? "img" : undefined}
      aria-label={title}
      aria-hidden={title ? undefined : true}
    >
      <mask id={maskId} maskUnits="userSpaceOnUse" x="0" y="0" width="100" height="100">
        <rect x="0" y="0" width="100" height="100" fill="#fff" />
        {/* Wider than the tail, so the channel leaves a little air either side. */}
        <path d="M49 55 L76 83" stroke="#000" strokeWidth="13" />
      </mask>

      <circle
        cx="50"
        cy="47"
        r="22"
        stroke="currentColor"
        strokeWidth="12.5"
        /* 2πr = 138.230; a quarter of that is 34.558 = 30.258 + 4.3. */
        strokeDasharray="30.258 4.3"
        /* Half a gap back, so a gap straddles the start point (3 o'clock)
           instead of a dash beginning there. */
        strokeDashoffset="-2.15"
        mask={`url(#${maskId})`}
      />

      <path d="M49 55 L74 81" stroke="var(--brand, #fa4f0c)" strokeWidth="9.5" />
    </svg>
  );
}

/** Mark plus the mono wordmark, locked up as the trading app does it. */
export function Wordmark({ size = 32, sub }) {
  return (
    <div style={{ display: "flex", alignItems: "center", gap: 10, minWidth: 0 }}>
      <LogoMark size={size} title="Quantrum" />
      <div style={{ minWidth: 0 }}>
        <div className="brand-name">Quantrum</div>
        {sub && <div className="brand-sub">{sub}</div>}
      </div>
    </div>
  );
}
