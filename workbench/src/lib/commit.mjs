function prettyJson(value) {
  return `${JSON.stringify(value, null, 2)}\n`;
}

function templateName(templateRef, result) {
  return result?.ir?.plan?.template_id || String(templateRef || "plan").split("@")[0] || "plan";
}

function recordFiles(records = []) {
  const months = new Map();
  for (const day of records || []) {
    const match = /^(\d{4})-(\d{2})-\d{2}$/.exec(day?.date || "");
    if (!match) continue;
    const [, year, month] = match;
    const monthKey = `${year}-${month}`;
    if (!months.has(monthKey)) months.set(monthKey, { year, month, days: [] });
    months.get(monthKey).days.push(day);
  }

  return [...months.entries()]
    .sort(([a], [b]) => a.localeCompare(b))
    .map(([monthKey, entry]) => ({
      path: `logs/${entry.year}/${entry.month}.json`,
      text: prettyJson({
        month: monthKey,
        days: entry.days.sort((a, b) => String(a.date || "").localeCompare(String(b.date || ""))),
      }),
    }));
}

/** Build the exact repo transaction the workbench should commit. */
export function buildCommitPlan({ state, result, lock, templateRef }) {
  if (!result) throw new Error("No engine build is available to commit.");

  const files = [
    { path: "plan.fitspec", text: state.planText },
    { path: "fitspec.lock", text: lock },
    { path: "state/current.json", text: prettyJson(state.currentState || result.state) },
    ...recordFiles(state.records),
    { path: "build/current.ir.json", text: prettyJson(result.ir) },
    { path: "build/next-workout.json", text: prettyJson(result.next_workout) },
    { path: "build/validation.json", text: prettyJson(result.validation) },
    ...state.patches
      .filter((patch) => patch.active !== false)
      .map((patch) => ({ path: `patches/${patch.filename}`, text: patch.text })),
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
