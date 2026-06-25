import { For, Show, createSignal } from "solid-js";
import { workbench } from "../workbench.js";
import { titleCase } from "../lib/format.js";

function mergeEvents(existing, incoming) {
  const merged = [...(existing || [])];
  const seen = new Set(merged.map((event) => event.id).filter(Boolean));
  let added = 0;
  for (const event of incoming || []) {
    if (event.id && seen.has(event.id)) continue;
    if (event.id) seen.add(event.id);
    merged.push(event);
    added++;
  }
  return { events: merged, added };
}

function importSetSummary(set) {
  return [set.load, set.reps ? `${set.reps} reps` : ""].filter(Boolean).join(" x ");
}

function importExerciseSummary(result) {
  const name = titleCase(result.performed_exercise || result.slot_id || "Exercise");
  const sets = (result.actual || []).slice(0, 4).map(importSetSummary).filter(Boolean);
  const more = (result.actual || []).length > sets.length ? ` +${result.actual.length - sets.length} sets` : "";
  return `${name}: ${sets.join(", ")}${more}`;
}

export default function History() {
  const [text, setText] = createSignal("");
  const [source, setSource] = createSignal("hevy");
  // { draft } | { error } | null
  const [outcome, setOutcome] = createSignal(null);

  const notice = () => workbench.state.ui?.historyNotice;

  const preview = () => {
    try {
      setOutcome({ draft: workbench.importHistory(text(), source()) });
    } catch (err) {
      setOutcome({ error: err.message });
    }
  };

  const accept = (draft) => {
    const merged = mergeEvents(workbench.state.events, draft.events);
    const skipped = draft.events.length - merged.added;
    const historyNotice = {
      kind: "ok",
      title: "Import added",
      message:
        skipped === 0
          ? `Added ${merged.added} imported session event${merged.added === 1 ? "" : "s"} to plan data.`
          : `Added ${merged.added} new session event${merged.added === 1 ? "" : "s"}; skipped ${skipped} duplicate${
              skipped === 1 ? "" : "s"
            }.`,
    };
    workbench.setState({ events: merged.events, ui: { ...workbench.state.ui, historyNotice } });
  };

  let dropEl;
  const onDrop = async (e) => {
    e.preventDefault();
    dropEl?.classList.remove("drag-over");
    const file = e.dataTransfer.files[0];
    if (file) setText(await file.text());
  };

  return (
    <div class="stack">
      <Show when={notice()}>
        <div class="card">
          <div class="card-head">
            <h3>{notice().title}</h3>
            <div class="row">
              <button onClick={() => workbench.setView("git")}>Commit imported data</button>
              <button class="ghost" onClick={() => workbench.setView("backtest")}>Review backtest</button>
            </div>
          </div>
          <p class={`msg ${notice().kind}`}>{notice().message}</p>
        </div>
      </Show>

      <div class="card">
        <div class="card-head">
          <h3>Import history</h3>
        </div>
        <p class="muted small">
          Paste or drop a CSV/TSV export (e.g. Hevy). The engine parses it — nothing is reimplemented here.
        </p>
        <div
          class="dropzone"
          ref={dropEl}
          onDragOver={(e) => {
            e.preventDefault();
            dropEl.classList.add("drag-over");
          }}
          onDragLeave={() => dropEl.classList.remove("drag-over")}
          onDrop={onDrop}
        >
          Drop a .csv / .tsv here, or paste below
        </div>
        <textarea
          spellcheck={false}
          placeholder={"completed_at,exercise,set,reps,load\n2026-01-02,squat,1,5,80kg"}
          value={text()}
          onInput={(e) => setText(e.target.value)}
        />
        <div class="row">
          <label>Source <input value={source()} onInput={(e) => setSource(e.target.value)} /></label>
          <button onClick={preview}>Preview import</button>
        </div>
      </div>

      <Show when={outcome()}>
        <Show
          when={!outcome().error}
          fallback={
            <div class="card">
              <p class="msg bad">{outcome().error}</p>
            </div>
          }
        >
          {(() => {
            const draft = outcome().draft;
            return (
              <div class="card">
                <div class="card-head">
                  <h4>
                    Parsed {draft.events.length} session events · {draft.imported_sets} sets from {draft.input_rows} rows
                  </h4>
                  <button onClick={() => accept(draft)}>Add to plan data</button>
                </div>
                <div class="timeline import-preview">
                  <For each={draft.events.slice(0, 40)}>
                    {(ev) => {
                      const results = ev.results || [];
                      const setCount = results.reduce((sum, r) => sum + (r.actual || []).length, 0);
                      const date = (ev.completed_at || "").replace("T00:00:00Z", "");
                      const detail = results.slice(0, 4).map(importExerciseSummary).join(" · ");
                      const more = results.length > 4 ? ` · +${results.length - 4} exercises` : "";
                      return (
                        <div class="import-row">
                          <div class="import-main">
                            <strong>{ev.reason || ev.session_id || ev.id}</strong>
                            <span class="muted small">{date}</span>
                          </div>
                          <span class="muted small">
                            {results.length} exercises · {setCount} sets
                          </span>
                          <span class="import-detail">{detail + more}</span>
                        </div>
                      );
                    }}
                  </For>
                </div>
              </div>
            );
          })()}
        </Show>
      </Show>
    </div>
  );
}
