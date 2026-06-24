import assert from "node:assert/strict";
import test from "node:test";

import { commitFiles, loadRepo } from "../src/github.js";

function jsonResponse(body, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });
}

function base64(text) {
  return Buffer.from(text, "utf8").toString("base64");
}

function installFetch(handler) {
  const calls = [];
  globalThis.fetch = async (url, options = {}) => {
    const call = { url: String(url), options };
    calls.push(call);
    return handler(call, calls);
  };
  return calls;
}

function requestJson(call) {
  return JSON.parse(call.options.body || "{}");
}

test("commitFiles creates one tree commit and one ref update", async () => {
  const calls = installFetch((call) => {
    const { url, options } = call;
    if (url.endsWith("/git/ref/heads/main")) return jsonResponse({ object: { sha: "base-commit" } });
    if (url.endsWith("/git/commits/base-commit")) return jsonResponse({ tree: { sha: "base-tree" } });
    if (url.endsWith("/git/blobs") && options.method === "POST") return jsonResponse({ sha: `blob-${calls.length}` });
    if (url.endsWith("/git/trees") && options.method === "POST") {
      const body = requestJson(call);
      assert.equal(body.base_tree, "base-tree");
      assert.deepEqual(body.tree.map((entry) => entry.path), ["plan.fitspec", "state/current.json"]);
      return jsonResponse({ sha: "new-tree" });
    }
    if (url.endsWith("/git/commits") && options.method === "POST") {
      const body = requestJson(call);
      assert.equal(body.message, "Update plan");
      assert.equal(body.tree, "new-tree");
      assert.deepEqual(body.parents, ["base-commit"]);
      return jsonResponse({ sha: "new-commit" });
    }
    if (url.endsWith("/git/refs/heads/main") && options.method === "PATCH") {
      assert.deepEqual(requestJson(call), { sha: "new-commit", force: false });
      return jsonResponse({ object: { sha: "new-commit" } });
    }
    throw new Error(`Unexpected request: ${options.method || "GET"} ${url}`);
  });

  const result = await commitFiles("token", "owner/repo", "main", {
    message: "Update plan",
    files: [
      { path: "plan.fitspec", text: "plan" },
      { path: "state/current.json", text: "{}\n" },
    ],
  });

  assert.equal(result.commitSha, "new-commit");
  assert.equal(result.committed, 2);
  assert.equal(calls.filter((call) => call.url.includes("/contents/")).length, 0);
  assert.equal(calls.filter((call) => call.url.endsWith("/git/commits") && call.options.method === "POST").length, 1);
});

test("commitFiles skips commit when the new tree matches the base tree", async () => {
  const calls = installFetch((call) => {
    const { url, options } = call;
    if (url.endsWith("/git/ref/heads/main")) return jsonResponse({ object: { sha: "base-commit" } });
    if (url.endsWith("/git/commits/base-commit")) return jsonResponse({ tree: { sha: "base-tree" } });
    if (url.endsWith("/git/blobs") && options.method === "POST") return jsonResponse({ sha: "same-blob" });
    if (url.endsWith("/git/trees") && options.method === "POST") return jsonResponse({ sha: "base-tree" });
    throw new Error(`Unexpected request: ${options.method || "GET"} ${url}`);
  });

  const result = await commitFiles("token", "owner/repo", "main", {
    message: "Update plan",
    files: [{ path: "plan.fitspec", text: "plan" }],
  });

  assert.equal(result.skipped, true);
  assert.equal(result.committed, 0);
  assert.equal(calls.some((call) => call.url.endsWith("/git/commits") && call.options.method === "POST"), false);
  assert.equal(calls.some((call) => call.url.endsWith("/git/refs/heads/main") && call.options.method === "PATCH"), false);
});

test("loadRepo reads plan, lock, patches, and JSONL logs from the git tree", async () => {
  const blobs = {
    "sha-plan": 'plan "Loaded" {}',
    "sha-lock": "lock",
    "sha-patch": 'patch "travel" {}',
    "sha-log": '{"id":"evt_1","type":"session_imported"}\nnot-json\n',
  };
  installFetch((call) => {
    const { url } = call;
    if (url.endsWith("/git/ref/heads/feature/test")) return jsonResponse({ object: { sha: "base-commit" } });
    if (url.endsWith("/git/commits/base-commit")) return jsonResponse({ tree: { sha: "base-tree" } });
    if (url.endsWith("/git/trees/base-tree?recursive=1")) {
      return jsonResponse({
        tree: [
          { type: "blob", path: "plan.fitspec", sha: "sha-plan" },
          { type: "blob", path: "fitspec.lock", sha: "sha-lock" },
          { type: "blob", path: "patches/travel.fitspec", sha: "sha-patch" },
          { type: "blob", path: "logs/imports/hevy.jsonl", sha: "sha-log" },
        ],
      });
    }
    const sha = url.split("/git/blobs/")[1];
    if (sha && blobs[sha]) return jsonResponse({ encoding: "base64", content: base64(blobs[sha]) });
    throw new Error(`Unexpected request: ${call.options.method || "GET"} ${url}`);
  });

  const loaded = await loadRepo("token", "owner/repo", "feature/test");

  assert.equal(loaded.planText, 'plan "Loaded" {}');
  assert.equal(loaded.lock, "lock");
  assert.equal(loaded.patches[0].name, "travel");
  assert.equal(loaded.patches[0].sha, "sha-patch");
  assert.equal(loaded.events.length, 1);
  assert.equal(loaded.repoLabel, "owner/repo@feature/test");
  assert.equal(loaded._loadWarnings.length, 1);
});
