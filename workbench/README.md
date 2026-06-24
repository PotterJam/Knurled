# Knurled Workbench

The workbench is a static, buildless site that runs the real Rust engine in the
browser via WebAssembly. It does not reimplement progression logic in JavaScript.

The deployable site root is this directory: `workbench/`.

## Local Serving

From the repository root:

```bash
cargo run -p knurled-cli -- serve --port 4321
```

Or serve this directory with any static file server. The workbench needs normal
HTTP serving for ES modules and WASM loading; opening `index.html` directly from
the filesystem is not the target path.

## Engine WASM

The generated engine artifacts in `workbench/engine/pkg/` are committed so the
site can deploy with no server-side build step.

Rebuild the WASM after any change to `engine/` or `workbench/engine-wasm/`:

```bash
rustup target add wasm32-unknown-unknown
cargo install wasm-bindgen-cli --version 0.2.100
npm run build:workbench
```

Commit the regenerated files in `workbench/engine/pkg/`.

## Cloudflare Pages

Deploy `workbench/` as the static output directory. The engine is included in the
committed WASM package at `workbench/engine/pkg/`, so Cloudflare does not need to
build Rust or WASM unless you choose to rebuild the engine during deployment.

Manual deployment with Wrangler:

```bash
npm run deploy:workbench
```

That runs:

```bash
npx wrangler pages deploy workbench
```

On first use, Wrangler will prompt you to log in, choose or create the Pages
project, and set the production branch.

Preview deployment:

```bash
npm run deploy:workbench:preview
```

For Cloudflare's Git integration, use the static HTML/none preset with:

- Build command: leave blank
- Build output directory: `workbench`
- Root directory: repository root

If you want Cloudflare to rebuild the WASM during deployment, set the build
command to:

```bash
rustup target add wasm32-unknown-unknown && cargo install wasm-bindgen-cli --version 0.2.100 && npm run build:workbench
```

The simpler path is to rebuild WASM locally after engine changes, commit
`workbench/engine/pkg/`, and keep Cloudflare's build command empty.
