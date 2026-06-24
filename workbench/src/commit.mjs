function slug(value) {
  let out = "";
  let lastWasSeparator = false;
  for (const ch of String(value || "").trim()) {
    if (/^[a-z0-9]$/i.test(ch)) {
      out += ch.toLowerCase();
      lastWasSeparator = false;
    } else if (!lastWasSeparator && out) {
      out += "_";
      lastWasSeparator = true;
    }
  }
  out = out.replace(/^_+|_+$/g, "");
  return out || "unknown";
}

function importedEventSource(event) {
  const program = event.program || "";
  if (program.startsWith("history_import:")) return slug(program.slice("history_import:".length));
  return "manual";
}

export function importedEventFiles(events) {
  const bySource = new Map();
  const seen = new Set();
  for (const event of events || []) {
    if ((event.type || event.kind) !== "session_imported") continue;
    if (event.id && seen.has(event.id)) continue;
    if (event.id) seen.add(event.id);
    const source = importedEventSource(event);
    if (!bySource.has(source)) bySource.set(source, []);
    bySource.get(source).push(event);
  }
  return [...bySource.entries()]
    .sort(([a], [b]) => a.localeCompare(b))
    .map(([source, sourceEvents]) => ({
      path: `logs/imports/${source}.jsonl`,
      text: sourceEvents.map((event) => JSON.stringify(event)).join("\n") + "\n",
    }));
}

function prettyJson(value) {
  return `${JSON.stringify(value, null, 2)}\n`;
}

function templateName(templateRef, result) {
  return result?.ir?.plan?.template_id || String(templateRef || "plan").split("@")[0] || "plan";
}

/** Build the exact repo transaction the workbench should commit. */
export function buildCommitPlan({ state, result, lock, templateRef }) {
  if (!result) throw new Error("No engine build is available to commit.");

  const files = [
    { path: "plan.fitspec", text: state.planText },
    { path: "fitspec.lock", text: lock },
    { path: "state/current.json", text: prettyJson(result.state) },
    { path: "build/current.ir.json", text: prettyJson(result.ir) },
    { path: "build/next-workout.json", text: prettyJson(result.next_workout) },
    { path: "build/validation.json", text: prettyJson(result.validation) },
    ...state.patches
      .filter((patch) => patch.active !== false)
      .map((patch) => ({ path: `patches/${patch.filename}`, text: patch.text })),
    ...importedEventFiles(state.events),
  ];

  const deletions = state.patches
    .filter((patch) => patch.active === false && patch.sha)
    .map((patch) => `patches/${patch.filename}`);

  return {
    files,
    deletions,
    message: `Update ${templateName(templateRef, result)} plan via workbench`,
  };
}
