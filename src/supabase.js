import { createClient } from "@supabase/supabase-js";

const url = import.meta.env.VITE_SUPABASE_URL;
const anonKey = import.meta.env.VITE_SUPABASE_ANON_KEY;

// Fail loudly at boot rather than with a confusing 401 on the first query.
export const configured = Boolean(url && anonKey && !url.includes("YOUR-PROJECT"));

export const supabase = configured
  ? createClient(url, anonKey, {
      auth: { persistSession: true, autoRefreshToken: true },
    })
  : null;

/**
 * Call one of the admin_* functions.
 *
 * Every read in this app goes through here. There is no table access at all —
 * `anon` is revoked from every table in this database, and the RPCs are
 * granted to `authenticated` and gated on the admin allow-list. So a signed-in
 * non-admin gets a clean "Not authorised", not a silent empty table.
 */
export async function rpc(name, args = {}) {
  if (!supabase) throw new Error("Supabase is not configured. Check admin-panel/.env");
  const { data, error } = await supabase.rpc(name, args);
  if (error) {
    // "The SQL has not been run yet" and "you are not an admin" are completely
    // different problems with completely different fixes, and conflating them
    // sends someone to edit an allow-list that does not exist. So the missing-
    // function case is detected first and tagged.
    //
    // PostgREST reports a missing function as PGRST202 ("...without parameters
    // in the schema cache"); Postgres itself uses 42883. Neither phrase is
    // worth string-matching alone, so both codes are named explicitly.
    if (
      error.code === "PGRST202" ||
      error.code === "42883" ||
      /schema cache|does not exist/i.test(error.message ?? "")
    ) {
      throw tagged(
        "setup",
        `${name}() is not in the database yet.`,
        // PostgREST's own text names the exact signature it looked for, which
        // is the difference between "the SQL never ran" and "it ran but the
        // arguments do not match". Paraphrasing it away made this
        // undiagnosable once already — so it is shown verbatim.
        [error.code, error.message, error.hint].filter(Boolean).join(" · ")
      );
    }
    if (error.message?.includes("Not authorised")) {
      throw tagged("forbidden", "Your account is not on the admin allow-list.");
    }
    throw tagged("error", error.message || "Query failed.",
                 [error.code, error.details, error.hint].filter(Boolean).join(" · "));
  }
  return data;
}

/** An Error that also says which failure shape it is, plus the raw server text. */
function tagged(kind, message, detail = "") {
  const err = new Error(message);
  err.kind = kind;
  err.detail = detail;
  return err;
}
