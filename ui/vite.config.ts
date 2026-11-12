import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
import tailwindcss from "@tailwindcss/vite";

// The build is served by server.ts from any path, hence the relative base.
// In dev, `npm run serve` (the node server on a fixture) answers /api.
export default defineConfig({
  base: "./",
  plugins: [react(), tailwindcss()],
  build: { outDir: "dist", emptyOutDir: true, sourcemap: false },
  server: { proxy: { "/api": "http://127.0.0.1:7180" } },
});
