import { defineConfig } from "vite";

// Relative base so the built site works from a GitHub Pages project subpath
// (https://<user>.github.io/VFR-radio-practice/) without hardcoding the repo name.
export default defineConfig({
  base: "./",
  build: { outDir: "dist", target: "es2022" },
});
