/* Formatting helpers. Money is rupees; the app rounds to whole rupees before
   it ever reaches Postgres, so nothing here shows paise. */

const NBSP = " ";

export function money(v, { compact = false } = {}) {
  const n = Number(v ?? 0);
  if (compact) return "₹" + NBSP + compactNum(n);
  return (
    "₹" +
    NBSP +
    n.toLocaleString("en-IN", { maximumFractionDigits: 0, minimumFractionDigits: 0 })
  );
}

export function signedMoney(v) {
  const n = Number(v ?? 0);
  const s = money(Math.abs(n));
  if (n > 0) return "+" + s;
  if (n < 0) return "−" + s;
  return s;
}

export function compactNum(n) {
  const a = Math.abs(n);
  if (a >= 1e7) return (n / 1e7).toFixed(a >= 1e8 ? 0 : 1) + " Cr";
  if (a >= 1e5) return (n / 1e5).toFixed(a >= 1e6 ? 0 : 1) + " L";
  if (a >= 1e3) return (n / 1e3).toFixed(a >= 1e4 ? 0 : 1) + "k";
  return String(Math.round(n));
}

export function num(v) {
  return Number(v ?? 0).toLocaleString("en-IN");
}

export function pct(v, digits = 1) {
  if (v === null || v === undefined || Number.isNaN(Number(v))) return "—";
  return Number(v).toFixed(digits) + "%";
}

/* Everything in the database is UTC. The team reads IST. Convert once, here. */
const IST = "Asia/Kolkata";

export function dateTime(v) {
  if (!v) return "—";
  return new Date(v).toLocaleString("en-IN", {
    timeZone: IST, day: "2-digit", month: "short", year: "numeric",
    hour: "2-digit", minute: "2-digit", hour12: true,
  });
}

export function timeOnly(v) {
  if (!v) return "—";
  return new Date(v).toLocaleTimeString("en-IN", {
    timeZone: IST, hour: "2-digit", minute: "2-digit", hour12: true,
  });
}

export function dateOnly(v) {
  if (!v) return "—";
  return new Date(v).toLocaleDateString("en-IN", {
    timeZone: IST, day: "2-digit", month: "short", year: "numeric",
  });
}

/** "3 minutes ago" — what an ops screen actually wants for a last-seen column. */
export function ago(v) {
  if (!v) return "never";
  const secs = (Date.now() - new Date(v).getTime()) / 1000;
  if (secs < 45) return "just now";
  const mins = secs / 60;
  if (mins < 60) return `${Math.round(mins)} min ago`;
  const hrs = mins / 60;
  if (hrs < 24) return `${Math.round(hrs)} hr${Math.round(hrs) === 1 ? "" : "s"} ago`;
  const days = hrs / 24;
  if (days < 31) return `${Math.round(days)} day${Math.round(days) === 1 ? "" : "s"} ago`;
  const months = days / 30.44;
  if (months < 12) return `${Math.round(months)} mo ago`;
  return `${(days / 365).toFixed(1)} yr ago`;
}

/** Chart axis label: "25 Aug" from an IST date string. */
export function shortDay(iso) {
  if (!iso) return "";
  const [y, m, d] = String(iso).split("-").map(Number);
  const dt = new Date(Date.UTC(y, m - 1, d));
  return dt.toLocaleDateString("en-IN", { timeZone: "UTC", day: "numeric", month: "short" });
}

export function provider(p) {
  if (!p) return "unknown";
  if (p === "google.com") return "Google";
  if (p === "password") return "Email";
  if (p === "phone") return "Phone";
  return p;
}
