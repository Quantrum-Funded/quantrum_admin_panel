import { useEffect, useState } from "react";
import { rpc } from "../supabase.js";

/**
 * Call an admin RPC and track loading/error.
 *
 * `deps` is stringified so an inline args object does not re-fire the effect on
 * every render — the classic way this hook turns into an infinite loop.
 */
export function useRpc(name, args, deps = []) {
  const [data, setData] = useState(null);
  const [error, setError] = useState("");
  const [loading, setLoading] = useState(true);
  const key = JSON.stringify([name, args, deps]);

  useEffect(() => {
    let alive = true;
    setLoading(true);
    rpc(name, args)
      .then((d) => { if (alive) { setData(d); setError(""); } })
      .catch((e) => { if (alive) setError(e.message); })
      .finally(() => { if (alive) setLoading(false); });
    return () => { alive = false; };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [key]);

  return { data, error, loading };
}
