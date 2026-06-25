import { defineConfig } from "vite";
import solid from "vite-plugin-solid";

// The workbench is a static SPA that runs the real Rust engine in the browser
// via WebAssembly. `base: "./"` keeps every emitted asset reference relative so
// the built `dist/` works behind Cloudflare Pages and the CLI's static server
// alike. The committed wasm-bindgen package in `engine/pkg/` is imported through
// `engine/index.js`; Vite bundles the `.wasm` as a hashed asset (see the
// `?url` import there), so no Rust toolchain is needed at site-build time.
export default defineConfig({
  plugins: [solid()],
  base: "./",
  build: {
    outDir: "dist",
    target: "esnext",
    emptyOutDir: true,
  },
});
