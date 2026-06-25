# Knurled Workbench

A [Vite](https://vite.dev) + [SolidJS](https://solidjs.com) single-page app that runs
the real Rust engine in the browser via WebAssembly. It does not reimplement progression
logic in JavaScript — validation, build, simulation, and history import all run in the
engine.

## Layout

- `index.html` — Vite entry.
- `src/main.jsx` — mounts the Solid app.
- `src/App.jsx` — shell (nav, status strip, view routing), boots the engine.
- `src/store.js` — persisted document state (plan text, lock, patches, events) on a Solid store.
- `src/workbench.js` — app-level reactive state and the single derived engine build.
- `src/views/*.jsx` — one component per view.
- `src/lib/` — framework-free helpers (`fitspec`, `github`, `commit`, `charts`).
- `engine/` — the WASM wrapper (`index.js`) and the committed wasm-bindgen package (`pkg/`).

## Develop

From the repository root (or `npm --prefix workbench …`):

```bash
npm run dev:workbench      # Vite dev server with hot module reload
```

Or from this directory:

```bash
npm install
npm run dev
```

## Build

```bash
npm run build:workbench    # from repo root → outputs workbench/dist/
# or, from this directory:
npm run build
```

The build bundles the committed WASM (`engine/pkg/knurled_engine_bg.wasm`) as a hashed
asset. `vite.config.js` sets `base: "./"` so every emitted reference is relative — the
`dist/` works behind Cloudflare Pages, the CLI static server, or any static host.

Preview the production build with the CLI's static server (build first):

```bash
npm run build:workbench
cargo run -p knurled-cli -- serve --port 4321
```

## Tests

The framework-free `lib/` modules have Node tests (no DOM, no engine):

```bash
npm test                   # from this directory
# or: npm run test:workbench   from the repo root
```

## Engine WASM

The generated engine artifacts in `engine/pkg/` are committed so the site builds with no
Rust toolchain. Rebuild after any change to `engine/` or `engine-wasm/`:

```bash
rustup target add wasm32-unknown-unknown
cargo install wasm-bindgen-cli --version 0.2.100
npm run build:wasm         # from the repo root → bash workbench/scripts/build-wasm.sh
```

Commit the regenerated files in `engine/pkg/`. The wrapper in `engine/index.js` imports
the `.wasm` with Vite's `?url` suffix and hands the URL to `init`, the reliable way to
load a wasm-bindgen `--target web` package under Vite.

## Cloudflare Pages

Deploy `workbench/dist/` as the static output. Since the WASM is committed, Cloudflare
does not need a Rust toolchain — only Node to run the Vite build.

Manual deployment with Wrangler (from the repo root):

```bash
npm run deploy:workbench          # builds then: wrangler pages deploy workbench/dist
npm run deploy:workbench:preview  # same, deploying to the preview branch
```

On first use, Wrangler will prompt you to log in, choose or create the Pages project, and
set the production branch.

For Cloudflare's Git integration, use these settings:

- Build command: `npm run build:workbench`
- Build output directory: `workbench/dist`
- Root directory: repository root

(Equivalently, set the root directory to `workbench` with build command `npm install &&
npm run build` and output `dist`.)
