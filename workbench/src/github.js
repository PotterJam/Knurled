// Browser-side GitHub access with a fine-grained PAT (spec §3A). The token is
// supplied by the caller from the store and lives only in this device's
// localStorage — it is never sent anywhere but api.github.com. No SDK; plain
// fetch keeps the workbench dependency-free.

const API = "https://api.github.com";

function headers(token) {
  return {
    Authorization: `Bearer ${token}`,
    Accept: "application/vnd.github+json",
    "X-GitHub-Api-Version": "2022-11-28",
  };
}

// UTF-8 safe base64 (btoa is latin1-only).
const b64encode = (text) => btoa(String.fromCharCode(...new TextEncoder().encode(text)));
const b64decode = (b64) =>
  new TextDecoder().decode(Uint8Array.from(atob(b64.replace(/\n/g, "")), (c) => c.charCodeAt(0)));

async function gh(token, path, options = {}) {
  const res = await fetch(`${API}${path}`, { ...options, headers: { ...headers(token), ...(options.headers || {}) } });
  if (!res.ok) {
    const body = await res.text();
    throw new Error(`GitHub ${res.status}: ${body.slice(0, 200)}`);
  }
  return res.status === 204 ? null : res.json();
}

async function getContent(token, repo, branch, path) {
  try {
    const data = await gh(token, `/repos/${repo}/contents/${path}?ref=${encodeURIComponent(branch)}`);
    return { text: b64decode(data.content), sha: data.sha };
  } catch (e) {
    if (String(e.message).includes("404")) return null;
    throw e;
  }
}

/** Load a training repo's plan, lock, patches and logs into a store-shaped object. */
export async function loadRepo(token, repo, branch) {
  const plan = await getContent(token, repo, branch, "plan.fitspec");
  if (!plan) throw new Error("No plan.fitspec found in that repo/branch.");
  const lock = await getContent(token, repo, branch, "fitspec.lock");

  const tree = await gh(token, `/repos/${repo}/git/trees/${encodeURIComponent(branch)}?recursive=1`);
  const files = tree.tree || [];

  const patches = [];
  for (const f of files.filter((f) => f.type === "blob" && /^patches\/.+\.fitspec$/.test(f.path))) {
    const c = await getContent(token, repo, branch, f.path);
    const name = c.text.match(/patch\s+"([^"]+)"/)?.[1] || f.path.split("/").pop();
    patches.push({ filename: f.path.split("/").pop(), text: c.text, name, active: true, sha: c.sha });
  }

  const events = [];
  for (const f of files.filter((f) => f.type === "blob" && /^logs\/.+\.jsonl$/.test(f.path))) {
    const c = await getContent(token, repo, branch, f.path);
    for (const line of c.text.split("\n").map((l) => l.trim()).filter(Boolean)) {
      try {
        events.push(JSON.parse(line));
      } catch {
        /* skip malformed log line */
      }
    }
  }

  return {
    planText: plan.text,
    lock: lock?.text || "",
    patches,
    events,
    repoLabel: `${repo}@${branch}`,
    _shas: { "plan.fitspec": plan.sha, "fitspec.lock": lock?.sha },
  };
}

/** Commit a set of { path, text } files in one batch via the contents API. */
export async function commitFiles(token, repo, branch, files, message) {
  for (const file of files) {
    let sha;
    const existing = await getContent(token, repo, branch, file.path);
    if (existing) sha = existing.sha;
    await gh(token, `/repos/${repo}/contents/${file.path}`, {
      method: "PUT",
      body: JSON.stringify({ message, content: b64encode(file.text), branch, ...(sha ? { sha } : {}) }),
    });
  }
  return { committed: files.length };
}

export async function whoami(token) {
  const me = await gh(token, "/user");
  return me.login;
}
