import { For, Show, createSignal } from "solid-js";
import { workbench } from "../workbench.js";
import { serializePatch } from "../lib/fitspec.js";

function PatchForm() {
  const [op, setOp] = createSignal("add-conditioning");
  const [name, setName] = createSignal("");
  // operation-specific fields
  const [fields, setFields] = createSignal({});
  const field = (key) => fields()[key] || "";
  const setField = (key, value) => setFields((f) => ({ ...f, [key]: value }));

  const save = () => {
    const patchName = name().trim() || "modification";
    let operation;
    if (op() === "add-conditioning") operation = { op: op(), day: field("day"), activity: field("activity") };
    else if (op() === "replace-exercise")
      operation = { op: op(), from: field("from"), to: field("to"), lane: field("lane") };
    else operation = { op: op(), target: field("target"), value: field("value"), lane: field("lane") || undefined };

    const text = serializePatch({ name: patchName, operations: [operation] });
    const filename = `${patchName.replace(/[^a-z0-9-]+/gi, "-").toLowerCase()}.fitspec`;
    workbench.setState({ patches: [...workbench.state.patches, { filename, name: patchName, text, active: true }] });
    setName("");
    setFields({});
  };

  return (
    <div class="card">
      <div class="card-head">
        <h3>New modification</h3>
      </div>
      <div class="form stack">
        <label>
          Name <input placeholder="shoulder-friendly-press" value={name()} onInput={(e) => setName(e.target.value)} />
        </label>
        <label>
          Type
          <select value={op()} onChange={(e) => setOp(e.target.value)}>
            <option value="add-conditioning">Add conditioning day</option>
            <option value="replace-exercise">Swap an exercise</option>
            <option value="cap">Cap a target</option>
          </select>
        </label>
        <div>
          <Show when={op() === "add-conditioning"}>
            <label>Day <input placeholder="sat" value={field("day")} onInput={(e) => setField("day", e.target.value)} /></label>
            <label>Activity <input placeholder="zone2 run 30m" value={field("activity")} onInput={(e) => setField("activity", e.target.value)} /></label>
          </Show>
          <Show when={op() === "replace-exercise"}>
            <label>From <input placeholder="overhead_press" value={field("from")} onInput={(e) => setField("from", e.target.value)} /></label>
            <label>To <input placeholder="incline_db_press" value={field("to")} onInput={(e) => setField("to", e.target.value)} /></label>
            <label>Lane regex <input placeholder="press\.t1" value={field("lane")} onInput={(e) => setField("lane", e.target.value)} /></label>
          </Show>
          <Show when={op() === "cap"}>
            <label>Target <input placeholder="rpe" value={field("target")} onInput={(e) => setField("target", e.target.value)} /></label>
            <label>Value <input placeholder="8" value={field("value")} onInput={(e) => setField("value", e.target.value)} /></label>
            <label>Lane regex (optional) <input placeholder="squat\..*" value={field("lane")} onInput={(e) => setField("lane", e.target.value)} /></label>
          </Show>
        </div>
        <div class="row">
          <button onClick={save}>Add modification</button>
        </div>
      </div>
    </div>
  );
}

export default function Patches() {
  const [showForm, setShowForm] = createSignal(false);
  const list = () => workbench.state.patches;

  const toggle = (i, checked) => {
    const next = list().slice();
    next[i] = { ...next[i], active: checked };
    workbench.setState({ patches: next });
  };
  const remove = (i) => {
    const next = list().slice();
    next.splice(i, 1);
    workbench.setState({ patches: next });
  };

  return (
    <div class="stack">
      <div class="card">
        <div class="card-head">
          <h3>Patches</h3>
          <button class="ghost" onClick={() => setShowForm(true)}>+ Add modification</button>
        </div>
        <p class="muted small">Layered, toggleable changes (injury, travel, deload). Recompiles live.</p>
        <Show when={list().length} fallback={<p class="muted">No patches yet.</p>}>
          <For each={list()}>
            {(p, i) => (
              <div class="patch-row">
                <label class="switch">
                  <input
                    type="checkbox"
                    checked={p.active !== false}
                    onChange={(e) => toggle(i(), e.target.checked)}
                  />
                  <span></span>
                </label>
                <div>
                  <strong>{p.name}</strong>
                  <pre class="patch-text">{p.text.trim()}</pre>
                </div>
                <button class="x" onClick={() => remove(i())}>×</button>
              </div>
            )}
          </For>
        </Show>
      </div>
      <Show when={showForm()}>
        <PatchForm />
      </Show>
    </div>
  );
}
