import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

// Port 5273 so it can never collide with `next dev` (3000) or the Worker
// backend (8787). Nothing here proxies to either — the panel talks only to
// Supabase.
export default defineConfig({
  plugins: [react()],
  server: { port: 5273, open: true },
});
