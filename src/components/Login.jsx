import React, { useState } from "react";
import { supabase, configured } from "../supabase.js";
import { Wordmark, LogoMark } from "./Logo.jsx";

/**
 * The admin team's own sign-in — Supabase Auth, entirely separate from the
 * Firebase accounts the trading app uses. A trader's password gets you nothing
 * here, and an admin password gets you nothing in the trading app.
 */
export default function Login() {
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState("");

  async function submit(e) {
    e.preventDefault();
    setErr("");
    setBusy(true);
    const { error } = await supabase.auth.signInWithPassword({ email, password });
    if (error) setErr(error.message);
    setBusy(false);
    // On success the auth listener in App.jsx swaps this screen out.
  }

  if (!configured) {
    return (
      <div className="login-wrap">
        <div className="login-card">
          <LogoMark size={34} title="Quantrum" />
          <h2 style={{ marginTop: 14 }}>Not configured</h2>
          <p className="sub">The panel has no Supabase credentials.</p>
          <div className="alert err">
            Create <code>admin-panel/.env</code> with <code>VITE_SUPABASE_URL</code> and{" "}
            <code>VITE_SUPABASE_ANON_KEY</code>, then restart <code>npm run dev</code>.
            There is an <code>.env.example</code> to copy.
          </div>
        </div>
      </div>
    );
  }

  return (
    <div className="login-wrap">
      <form className="login-card" onSubmit={submit}>
        <div className="brand" style={{ padding: "0 0 18px" }}>
          <Wordmark size={34} sub="Admin dashboard" />
        </div>

        <h2>Admin sign in</h2>
        <p className="sub">Internal use only. Ask an owner to add your account.</p>

        {err && <div className="alert err">{err}</div>}

        <div className="field">
          <label htmlFor="email">Work email</label>
          <input
            id="email" className="input" type="email" required autoFocus
            autoComplete="username" value={email}
            onChange={(e) => setEmail(e.target.value)}
            placeholder="you@quantrum.in"
          />
        </div>

        <div className="field">
          <label htmlFor="password">Password</label>
          <input
            id="password" className="input" type="password" required
            autoComplete="current-password" value={password}
            onChange={(e) => setPassword(e.target.value)}
            placeholder="••••••••"
          />
        </div>

        <button className="btn primary" style={{ width: "100%", marginTop: 8 }} disabled={busy}>
          {busy ? "Signing in…" : "Sign in"}
        </button>

        <div className="tip" style={{ marginTop: 16 }}>
          This dashboard is read-only. It can look at every account, and it
          cannot change one.
        </div>
      </form>
    </div>
  );
}
