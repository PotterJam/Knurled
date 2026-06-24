import assert from "node:assert/strict";
import test from "node:test";

import { buildCommitPlan } from "../src/commit.mjs";

test("buildCommitPlan includes canonical and generated workbench files", () => {
  const state = {
    planText: "plan text",
    patches: [
      { filename: "active.fitspec", text: "patch active", active: true },
      { filename: "inactive.fitspec", text: "patch inactive", active: false, sha: "old-patch" },
      { filename: "draft.fitspec", text: "patch draft", active: false },
    ],
    events: [
      {
        id: "evt_import_1",
        type: "session_imported",
        program: "history_import:hevy",
        results: [],
      },
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
      "build/current.ir.json",
      "build/next-workout.json",
      "build/validation.json",
      "patches/active.fitspec",
      "logs/imports/hevy.jsonl",
    ],
  );
  assert.deepEqual(plan.deletions, ["patches/inactive.fitspec"]);
  assert.equal(plan.message, "Update gzcl.gzclp plan via workbench");
  assert.match(plan.files.find((file) => file.path === "state/current.json").text, /"cursor"/);
});
