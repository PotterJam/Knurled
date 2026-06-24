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
