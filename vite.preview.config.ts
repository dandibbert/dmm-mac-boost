import { resolve } from "node:path";
import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
import tailwindcss from "@tailwindcss/vite";

export default defineConfig({
  root: resolve("src/renderer"),
  resolve: {
    alias: {
      "@": resolve("src/renderer/src"),
    },
  },
  plugins: [react(), tailwindcss()],
  server: {
    host: "127.0.0.1",
    port: 43173,
    strictPort: true,
  },
});
