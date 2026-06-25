import assert from "node:assert/strict";
import test from "node:test";

import { buildCommitPlan } from "../src/lib/commit.mjs";

test("buildCommitPlan includes canonical and generated workbench files", () => {
  const state = {
    planText: "plan text",
    patches: [
      { filename: "active.fitspec", text: "patch active", active: true },
      { filename: "inactive.fitspec", text: "patch inactive", active: false, sha: "old-patch" },
      { filename: "draft.fitspec", text: "patch draft", active: false },
    ],
    currentState: { cursor: { next: "B1" } },
    records: [
      { date: "2026-06-24", lifts: [{ exercise: "squat", weight: "80kg", sets: [5, 5, 7] }] },
      { date: "2026-06-22", program: "gzcl.gzclp", lifts: [] },
    ],
  };
  const result = {
    state: { cursor: { next: "A1" } },
    ir: { plan: { template_id: "gzcl.gzclp" } },
    next_workout: { session_id: "A1" },
    validation: { status: "valid" },
  };

  const plan = buildCommitPlan({ state, result, lock: "lock text", templateRef: "gzcl.gzclp@1.0.0" });

  assert.deepEqual(
    plan.files.map((file) => file.path),
    [
      "plan.fitspec",
      "fitspec.lock",
      "state/current.json",
      "logs/2026/06.json",
      "build/current.ir.json",
      "build/next-workout.json",
      "build/validation.json",
      "patches/active.fitspec",
    ],
  );
  assert.deepEqual(plan.deletions, ["patches/inactive.fitspec"]);
  assert.equal(plan.message, "Update gzcl.gzclp plan via workbench");
  assert.match(plan.files.find((file) => file.path === "state/current.json").text, /"B1"/);
  assert.match(plan.files.find((file) => file.path === "logs/2026/06.json").text, /"squat"/);
});
