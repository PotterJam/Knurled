import { For, Show, createSignal, createEffect, onMount } from "solid-js";
import { workbench } from "../workbench.js";
import { titleCase } from "../lib/format.js";
import { parsePlan } from "../lib/fitspec.js";

// --------------------------------------------------------------------------
// Shared validation rail
// --------------------------------------------------------------------------
function ValidationRail() {
  const build = () => workbench.build();
  const messages = () => {
    const v = build().result?.validation;
    if (!v) return [];
    return [...v.errors.map((e) => ["bad", e]), ...v.warnings.map((w) => ["warn", w])];
  };
  return (
    <div class="validation-rail">
      <Show when={!build().error} fallback={<p class="msg bad">{build().error}</p>}>
        <Show when={build().result?.validation}>
          <Show when={messages().length} fallback={<p class="msg ok">Plan is valid.</p>}>
            <For each={messages()}>
              {([kind, msg]) => (
                <p class={`msg ${kind}`}>
                  <code>{msg.code || ""}</code> {msg.message}
                </p>
              )}
            </For>
          </Show>
        </Show>
      </Show>
    </div>
  );
}

// --------------------------------------------------------------------------
// Raw editor — textarea stays mounted; only the validation rail recomputes.
// --------------------------------------------------------------------------
function RawEditor() {
  let ta;
  onMount(() => {
    ta.value = workbench.state.planText;
  });
  // Reflect external plan-text changes (form/builder edits, repo load, reset)
  // without clobbering the caret while the user is typing in this textarea.
  createEffect(() => {
    const text = workbench.state.planText;
    if (ta && ta.value !== text) ta.value = text;
  });
  return (
    <>
      <textarea id="raw" ref={ta} spellcheck={false} onInput={(e) => workbench.setPlanText(e.target.value)} />
      <ValidationRail />
    </>
  );
}

// --------------------------------------------------------------------------
// Form editor
// --------------------------------------------------------------------------
function FormEditor() {
  const model = () => parsePlan(workbench.state.planText);
  const lifts = () => {
    const m = model();
    return Object.keys({ ...m.starts, ...m.trainingMaxes, squat: 1, bench: 1, press: 1, deadlift: 1 });
  };

  // Each edit re-parses the canonical text, applies the one change, re-serializes.
  const edit = (mutate) => {
    const next = parsePlan(workbench.state.planText);
    mutate(next);
    workbench.setPlanModel(next);
  };

  return (
    <div class="form stack">
      <label>
        Plan name
        <input value={model().name} onChange={(e) => edit((m) => (m.name = e.target.value || "Untitled Plan"))} />
      </label>
      <div class="row">
        <label>
          Template
          <select
            onChange={(e) =>
              edit((m) => {
                const ref = e.target.value;
                [m.templateId, m.templateVersion] = ref.includes("@") ? ref.split("@") : [ref, m.templateVersion];
              })
            }
          >
            <For each={workbench.templates()}>
              {(t) => (
                <option value={t.ref} selected={t.id === model().templateId}>
                  {t.display_name}
                </option>
              )}
            </For>
          </select>
        </label>
        <label>
          Units
          <select value={model().units} onChange={(e) => edit((m) => (m.units = e.target.value))}>
            <option value="kg">kg</option>
            <option value="lb">lb</option>
          </select>
        </label>
      </div>
      <label>
        Rotation
        <input
          value={model().rotation.join(" ")}
          onChange={(e) => edit((m) => (m.rotation = e.target.value.trim().split(/\s+/).filter(Boolean)))}
        />
      </label>
      <label>
        Suggested days
        <input
          value={model().suggestedDays.join(" ")}
          onChange={(e) => edit((m) => (m.suggestedDays = e.target.value.trim().split(/\s+/).filter(Boolean)))}
        />
      </label>
      <fieldset>
        <legend>Starting weights</legend>
        <div class="grid2">
          <For each={lifts()}>
            {(lift) => (
              <label>
                {titleCase(lift)}
                <input
                  value={model().starts[lift] || model().trainingMaxes[lift] || ""}
                  onChange={(e) =>
                    edit((m) => {
                      const v = e.target.value.trim();
                      if (v) m.starts[lift] = v;
                      else delete m.starts[lift];
                    })
                  }
                />
              </label>
            )}
          </For>
        </div>
      </fieldset>
      <ValidationRail />
    </div>
  );
}

// --------------------------------------------------------------------------
// Builder (drag & drop)
// --------------------------------------------------------------------------
function SessionCard(props) {
  const m = () => props.model;
  return (
    <div class="session card">
      <h3>{props.name}</h3>
      <For each={props.slots}>
        {(slot) => {
          const isAccessory = !!slot.accessory_key;
          const key = slot.accessory_key;
          const current = () =>
            isAccessory
              ? m().accessories[key] || slot.default_exercise || ""
              : slot.exercise || slot.default_exercise || "";
          const opt = () => (isAccessory ? m().exerciseOptions[key] : null);
          return (
            <div class={`slot ${isAccessory ? "editable" : "locked"}`}>
              <span class="tier">{(slot.tier || "").toUpperCase()}</span>
              <Show
                when={isAccessory}
                fallback={<span class="slot-fixed">{titleCase(current())}</span>}
              >
                <div
                  class="slot-drop"
                  data-slot-key={key}
                  data-role="primary"
                  onDragOver={(e) => {
                    e.preventDefault();
                    e.currentTarget.classList.add("drag-over");
                  }}
                  onDragLeave={(e) => e.currentTarget.classList.remove("drag-over")}
                  onDrop={(e) => props.onDropPrimary(e, key)}
                >
                  {current() ? titleCase(current()) : "drop an exercise"}
                </div>
                <div class="alts">
                  <For each={opt()?.alternatives || []}>
                    {(a) => (
                      <span class="alt-chip">
                        {a.label}
                        <button
                          class={`policy ${a.policy}`}
                          title="toggle policy"
                          onClick={() => props.onTogglePolicy(key, a.id)}
                        >
                          {a.policy === "progression_equivalent" ? "≡" : "~"}
                        </button>
                        <button class="x" onClick={() => props.onRemoveAlt(key, a.id)}>×</button>
                      </span>
                    )}
                  </For>
                  <span
                    class="alt-drop"
                    data-slot-key={key}
                    data-role="alt"
                    onDragOver={(e) => {
                      e.preventDefault();
                      e.currentTarget.classList.add("drag-over");
                    }}
                    onDragLeave={(e) => e.currentTarget.classList.remove("drag-over")}
                    onDrop={(e) => props.onDropAlt(e, key)}
                  >
                    + alternative
                  </span>
                </div>
              </Show>
            </div>
          );
        }}
      </For>
    </div>
  );
}

function BuilderEditor() {
  const [search, setSearch] = createSignal("");
  let dragIdx = null;

  const model = () => parsePlan(workbench.state.planText);
  const tpl = () => workbench.templates().find((t) => t.id === model().templateId) || workbench.templates()[0];
  const sessions = () => Object.entries(tpl()?.skeleton?.sessions || {});

  const byPattern = () => {
    const groups = {};
    for (const ex of workbench.exercises()) (groups[ex.pattern] ||= []).push(ex);
    return Object.entries(groups);
  };

  const edit = (mutate) => {
    const next = parsePlan(workbench.state.planText);
    mutate(next);
    workbench.setPlanModel(next);
  };

  const onDropPrimary = (e, key) => {
    e.preventDefault();
    e.currentTarget.classList.remove("drag-over");
    const ex = e.dataTransfer.getData("text/exercise");
    if (!ex) return;
    edit((next) => (next.accessories[key] = ex));
  };
  const onDropAlt = (e, key) => {
    e.preventDefault();
    e.currentTarget.classList.remove("drag-over");
    const ex = e.dataTransfer.getData("text/exercise");
    if (!ex) return;
    edit((next) => {
      const opt = (next.exerciseOptions[key] ||= { primary: next.accessories[key] || "", alternatives: [] });
      if (!opt.alternatives.some((a) => a.id === ex)) {
        const label = workbench.exercises().find((x) => x.id === ex)?.label || titleCase(ex);
        opt.alternatives.push({ id: ex, label, policy: "tracking_only" });
      }
    });
  };
  const onRemoveAlt = (key, id) =>
    edit((next) => {
      const opt = next.exerciseOptions[key];
      if (opt) opt.alternatives = opt.alternatives.filter((a) => a.id !== id);
    });
  const onTogglePolicy = (key, id) =>
    edit((next) => {
      const alt = next.exerciseOptions[key]?.alternatives.find((a) => a.id === id);
      if (alt) alt.policy = alt.policy === "tracking_only" ? "progression_equivalent" : "tracking_only";
    });

  const toggleDay = (d) =>
    edit((next) => {
      next.suggestedDays = next.suggestedDays.includes(d)
        ? next.suggestedDays.filter((x) => x !== d)
        : [...next.suggestedDays, d];
    });

  const onRotationDrop = (target) => {
    if (dragIdx === null || dragIdx === target) return;
    edit((next) => {
      const [moved] = next.rotation.splice(dragIdx, 1);
      next.rotation.splice(target, 0, moved);
    });
    dragIdx = null;
  };

  const addCustom = () => {
    const id = prompt("Exercise id (snake_case), e.g. landmine_press");
    if (id) {
      const clean = id.trim().toLowerCase().replace(/\s+/g, "_");
      workbench.addCustomExercise({ id: clean, label: titleCase(clean), pattern: "custom", muscles: [] });
    }
  };

  const matches = (ex) => ex.label.toLowerCase().includes(search().toLowerCase());

  return (
    <div class="builder">
      <aside class="palette">
        <input placeholder="Search exercises…" value={search()} onInput={(e) => setSearch(e.target.value)} />
        <div class="palette-list">
          <For each={byPattern()}>
            {([pattern, items]) => (
              <Show when={items.some(matches)}>
                <div class="palette-group">
                  <h4>{titleCase(pattern)}</h4>
                  <For each={items}>
                    {(ex) => (
                      <div
                        class="ex-chip"
                        draggable="true"
                        title={ex.muscles.join(", ")}
                        style={matches(ex) ? undefined : "display:none"}
                        onDragStart={(e) => e.dataTransfer.setData("text/exercise", ex.id)}
                      >
                        {ex.label}
                      </div>
                    )}
                  </For>
                </div>
              </Show>
            )}
          </For>
        </div>
        <button class="ghost" onClick={addCustom}>+ Custom exercise</button>
      </aside>

      <div class="canvas stack">
        <section class="card">
          <h3>Rotation</h3>
          <p class="muted small">Drag to reorder the session cycle.</p>
          <div class="rotation">
            <For each={model().rotation}>
              {(s, i) => (
                <span
                  class="rot-chip"
                  draggable="true"
                  onDragStart={() => (dragIdx = i())}
                  onDragOver={(e) => e.preventDefault()}
                  onDrop={() => onRotationDrop(i())}
                >
                  {s}
                </span>
              )}
            </For>
          </div>
          <div class="days">
            <For each={["mon", "tue", "wed", "thu", "fri", "sat", "sun"]}>
              {(d) => (
                <button
                  class="day"
                  classList={{ on: model().suggestedDays.includes(d) }}
                  onClick={() => toggleDay(d)}
                >
                  {d}
                </button>
              )}
            </For>
          </div>
        </section>

        <section class="sessions">
          <For each={sessions()}>
            {([name, slots]) => (
              <SessionCard
                name={name}
                slots={slots}
                model={model()}
                onDropPrimary={onDropPrimary}
                onDropAlt={onDropAlt}
                onRemoveAlt={onRemoveAlt}
                onTogglePolicy={onTogglePolicy}
              />
            )}
          </For>
        </section>
      </div>
    </div>
  );
}

// --------------------------------------------------------------------------
// Editor shell with subtabs
// --------------------------------------------------------------------------
const TABS = ["builder", "form", "raw"];

export default function Editor() {
  const [tab, setTab] = createSignal("builder");
  const status = () => workbench.build().result?.validation?.status || "error";

  return (
    <>
      <div class="subtabs">
        <For each={TABS}>
          {(t) => (
            <button class="subtab" classList={{ active: t === tab() }} onClick={() => setTab(t)}>
              {titleCase(t)}
            </button>
          )}
        </For>
        <span class="grow"></span>
        <span class={`pill ${status() === "valid" ? "ok" : "bad"}`}>{status()}</span>
      </div>
      <div class="editor-body">
        <Show when={tab() === "raw"}>
          <RawEditor />
        </Show>
        <Show when={tab() === "form"}>
          <FormEditor />
        </Show>
        <Show when={tab() === "builder"}>
          <BuilderEditor />
        </Show>
      </div>
    </>
  );
}
