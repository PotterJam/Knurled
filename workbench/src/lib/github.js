// Browser-side GitHub access with a fine-grained PAT (spec §3A). The token is
// supplied by the caller from the store and lives only in this device's
// localStorage. Commits use Git's blob/tree/commit/ref flow so a workbench save
// moves the branch once instead of creating one commit per file.

const API = "https://api.github.com";

function parseRepo(repo) {
  const value = String(repo || "").trim();
  const parts = value.split("/");
  if (parts.length !== 2 || !parts[0] || !parts[1]) {
    throw new Error("Repo must be in owner/name format.");
  }
  return {
    owner: parts[0],
    name: parts[1],
    path: `${encodeURIComponent(parts[0])}/${encodeURIComponent(parts[1])}`,
    label: `${parts[0]}/${parts[1]}`,
  };
}

function requireToken(token) {
  if (!String(token || "").trim()) throw new Error("GitHub token is required.");
  return token.trim();
}

function requireBranch(branch) {
  const value = String(branch || "").trim() || "main";
  if (value.startsWith("/") || value.endsWith("/") || value.includes("..")) {
    throw new Error("Branch name is invalid.");
  }
  return value;
}

function encodePath(value) {
  return String(value).split("/").map(encodeURIComponent).join("/");
}

function headers(token, hasBody = false) {
  return {
    Authorization: `Bearer ${token}`,
    Accept: "application/vnd.github+json",
    "X-GitHub-Api-Version": "2022-11-28",
    ...(hasBody ? { "Content-Type": "application/json" } : {}),
  };
}

function decodeBase64(text) {
  const compact = String(text || "").replace(/\s/g, "");
  if (typeof atob === "function") {
    return new TextDecoder().decode(Uint8Array.from(atob(compact), (c) => c.charCodeAt(0)));
  }
  return globalThis.Buffer.from(compact, "base64").toString("utf8");
}

function errorMessage(status, bodyText, data) {
  const message = data?.message || bodyText || "request failed";
  const details = Array.isArray(data?.errors)
    ? data.errors.map((e) => e.message || e.code || JSON.stringify(e)).filter(Boolean).join("; ")
    : "";
  return `GitHub ${status}: ${details ? `${message} (${details})` : message}`;
}

async function gh(token, path, options = {}) {
  const body = options.body;
  const res = await fetch(`${API}${path}`, {
    ...options,
    headers: { ...headers(token, body != null), ...(options.headers || {}) },
  });
  const bodyText = await res.text();
  let data = null;
  if (bodyText) {
    try {
      data = JSON.parse(bodyText);
    } catch {
      /* keep raw body text for error reporting */
    }
  }
  if (!res.ok) throw new Error(errorMessage(res.status, bodyText.slice(0, 500), data));
  return data;
}

function repoPath(repo, suffix) {
  return `/repos/${parseRepo(repo).path}${suffix}`;
}

function refPath(branch) {
  return encodePath(`heads/${requireBranch(branch)}`);
}

async function getBranchRef(token, repo, branch) {
  return gh(token, repoPath(repo, `/git/ref/${refPath(branch)}`));
}

async function getCommit(token, repo, sha) {
  return gh(token, repoPath(repo, `/git/commits/${encodeURIComponent(sha)}`));
}

async function getRecursiveTree(token, repo, treeSha) {
  const tree = await gh(token, repoPath(repo, `/git/trees/${encodeURIComponent(treeSha)}?recursive=1`));
  if (tree.truncated) {
    throw new Error("GitHub returned a truncated repository tree; load a smaller training repo or use the CLI.");
  }
  return tree.tree || [];
}

async function getBlobText(token, repo, sha) {
  const blob = await gh(token, repoPath(repo, `/git/blobs/${encodeURIComponent(sha)}`));
  if (blob.encoding === "base64") return decodeBase64(blob.content);
  if (blob.encoding === "utf-8" || blob.encoding === "utf8") return blob.content || "";
  throw new Error(`Unsupported GitHub blob encoding: ${blob.encoding || "unknown"}`);
}

function findBlob(tree, path) {
  return tree.find((entry) => entry.type === "blob" && entry.path === path) || null;
}

async function readBlobPath(token, repo, tree, path) {
  const entry = findBlob(tree, path);
  if (!entry) return null;
  return { text: await getBlobText(token, repo, entry.sha), sha: entry.sha };
}

// ADR 0007: a log file is one pretty-printed month (`logs/<yyyy>/<mm>.json`)
// holding `days[]`. Parse a month, returning its day records; malformed files
// are skipped with a warning rather than failing the load.
function parseRecordMonth(text, path, warnings) {
  try {
    const month = JSON.parse(text);
    return Array.isArray(month?.days) ? month.days : [];
  } catch (error) {
    warnings.push(`${path}: skipped malformed record (${error.message})`);
    return [];
  }
}

/** Load a training repo's plan, lock, patches and logs into a store-shaped object. */
export async function loadRepo(token, repo, branch = "main") {
  token = requireToken(token);
  branch = requireBranch(branch);
  const parsed = parseRepo(repo);
  const ref = await getBranchRef(token, parsed.label, branch);
  const commit = await getCommit(token, parsed.label, ref.object.sha);
  const tree = await getRecursiveTree(token, parsed.label, commit.tree.sha);

  const plan = await readBlobPath(token, parsed.label, tree, "plan.fitspec");
  if (!plan) throw new Error("No plan.fitspec found in that repo/branch.");
  const lock = await readBlobPath(token, parsed.label, tree, "fitspec.lock");

  const patches = [];
  for (const entry of tree
    .filter((item) => item.type === "blob" && /^patches\/.+\.fitspec$/.test(item.path))
    .sort((a, b) => a.path.localeCompare(b.path))) {
    const text = await getBlobText(token, parsed.label, entry.sha);
    const name = text.match(/patch\s+"([^"]+)"/)?.[1] || entry.path.split("/").pop();
    patches.push({ filename: entry.path.split("/").pop(), text, name, active: true, sha: entry.sha });
  }

  const loadWarnings = [];
  const records = [];
  for (const entry of tree
    .filter((item) => item.type === "blob" && /^logs\/.+\.json$/.test(item.path))
    .sort((a, b) => a.path.localeCompare(b.path))) {
    records.push(...parseRecordMonth(await getBlobText(token, parsed.label, entry.sha), entry.path, loadWarnings));
  }
  records.sort((a, b) => String(a.date).localeCompare(String(b.date)));

  // state/current.json is the source of truth (ADR 0007); load it if present.
  const stateBlob = await readBlobPath(token, parsed.label, tree, "state/current.json");
  let currentState = null;
  if (stateBlob) {
    try {
      currentState = JSON.parse(stateBlob.text);
    } catch (error) {
      loadWarnings.push(`state/current.json: skipped malformed state (${error.message})`);
    }
  }

  return {
    planText: plan.text,
    lock: lock?.text || "",
    patches,
    records,
    currentState,
    repoLabel: `${parsed.label}@${branch}`,
    _base: { branch, commitSha: ref.object.sha, treeSha: commit.tree.sha },
    _shas: { "plan.fitspec": plan.sha, "fitspec.lock": lock?.sha },
    _loadWarnings: loadWarnings,
  };
}

function normalizeCommitPlan(filesOrPlan, message) {
  const plan = Array.isArray(filesOrPlan)
    ? { files: filesOrPlan, deletions: [], message }
    : { deletions: [], ...(filesOrPlan || {}) };

  const filesByPath = new Map();
  for (const file of plan.files || []) {
    const path = String(file.path || "").replace(/^\/+/, "");
    if (!path) throw new Error("Commit file path cannot be empty.");
    filesByPath.set(path, { path, text: String(file.text ?? "") });
  }

  const deletions = [...new Set((plan.deletions || []).map((path) => String(path || "").replace(/^\/+/, "")).filter(Boolean))]
    .filter((path) => !filesByPath.has(path));

  return {
    files: [...filesByPath.values()].sort((a, b) => a.path.localeCompare(b.path)),
    deletions: deletions.sort((a, b) => a.localeCompare(b)),
    message: String(plan.message || message || "Update Knurled plan via workbench").trim(),
  };
}

async function createBlob(token, repo, text) {
  return gh(token, repoPath(repo, "/git/blobs"), {
    method: "POST",
    body: JSON.stringify({ content: text, encoding: "utf-8" }),
  });
}

/** Commit a set of repo file changes as one Git commit and one ref update. */
export async function commitFiles(token, repo, branch = "main", filesOrPlan, message) {
  token = requireToken(token);
  branch = requireBranch(branch);
  const parsed = parseRepo(repo);
  const plan = normalizeCommitPlan(filesOrPlan, message);
  if (!plan.files.length && !plan.deletions.length) {
    return { committed: 0, skipped: true, changedFiles: [], message: "No files to commit." };
  }

  const ref = await getBranchRef(token, parsed.label, branch);
  const baseCommitSha = ref.object.sha;
  const baseCommit = await getCommit(token, parsed.label, baseCommitSha);
  const baseTreeSha = baseCommit.tree.sha;

  const blobEntries = await Promise.all(
    plan.files.map(async (file) => {
      const blob = await createBlob(token, parsed.label, file.text);
      return { path: file.path, mode: "100644", type: "blob", sha: blob.sha };
    }),
  );
  const deleteEntries = plan.deletions.map((path) => ({ path, mode: "100644", type: "blob", sha: null }));
  const tree = await gh(token, repoPath(parsed.label, "/git/trees"), {
    method: "POST",
    body: JSON.stringify({ base_tree: baseTreeSha, tree: [...blobEntries, ...deleteEntries] }),
  });

  const changedFiles = [...plan.files.map((file) => file.path), ...plan.deletions].sort((a, b) => a.localeCompare(b));
  if (tree.sha === baseTreeSha) {
    return { committed: 0, skipped: true, changedFiles, message: "No changes to commit." };
  }

  const commit = await gh(token, repoPath(parsed.label, "/git/commits"), {
    method: "POST",
    body: JSON.stringify({ message: plan.message, tree: tree.sha, parents: [baseCommitSha] }),
  });

  await gh(token, repoPath(parsed.label, `/git/refs/${refPath(branch)}`), {
    method: "PATCH",
    body: JSON.stringify({ sha: commit.sha, force: false }),
  });

  return {
    committed: changedFiles.length,
    commitSha: commit.sha,
    htmlUrl: `https://github.com/${parsed.label}/commit/${commit.sha}`,
    changedFiles,
    skipped: false,
  };
}

export async function whoami(token) {
  const me = await gh(requireToken(token), "/user");
  return me.login;
}
