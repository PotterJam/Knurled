import { For, Show, createMemo, createSignal } from "solid-js";
import { workbench } from "../workbench.js";
import { titleCase } from "../lib/format.js";

function normalizeRecords(value) {
  if (Array.isArray(value)) return value;
  if (Array.isArray(value?.records)) return value.records;
  if (value?.date) return [value];
  throw new Error("Paste a TrainingRecord, a TrainingRecord array, or a LogMonth with a records array.");
}

function liftSummary(lift) {
  const name = titleCase(lift.exercise || "Exercise");
  const weight = lift.weight ? ` ${lift.weight}` : "";
  const sets = (lift.sets || []).length ? ` ${(lift.sets || []).join("/")}` : "";
  return `${name}${weight}${sets}`;
}

function recordDetail(day) {
  const lifts = (day.lifts || []).slice(0, 4).map(liftSummary);
  const more = (day.lifts || []).length > lifts.length ? ` · +${day.lifts.length - lifts.length} lifts` : "";
  return [day.program ? `Program ${day.program}` : "", lifts.join(" · ") + more, day.note].filter(Boolean).join(" · ");
}

const sampleMonth = JSON.stringify(
  {
    month: "2026-06",
    format_version: 1,
    records: [],
  },
  null,
  2,
);

export default function History() {
  const [text, setText] = createSignal("");
  const [outcome, setOutcome] = createSignal(null);

  const notice = () => workbench.state.ui?.historyNotice;
  const records = createMemo(() => workbench.state.records || []);

  const preview = () => {
    try {
      setOutcome({ records: normalizeRecords(JSON.parse(text())) });
    } catch (err) {
      setOutcome({ error: err.message });
    }
  };

  const accept = (incomingRecords) => {
    const existingIds = new Set(records().map((record) => record.id));
    const merged = workbench.engineMergeRecords(records(), incomingRecords);
    const added = incomingRecords.filter((record) => !existingIds.has(record.id)).length;
    const historyNotice = {
      kind: "ok",
      title: "Records updated",
      message: `Added ${added} record${added === 1 ? "" : "s"}.`,
    };
    workbench.setState({ records: merged, ui: { ...workbench.state.ui, historyNotice } });
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
              <button onClick={() => workbench.setView("git")}>Commit records</button>
              <button class="ghost" onClick={() => workbench.setView("backtest")}>Review backtest</button>
            </div>
          </div>
          <p class={`msg ${notice().kind}`}>{notice().message}</p>
        </div>
      </Show>

      <div class="card">
        <div class="card-head">
          <h3>Records</h3>
          <span class="pill ok">{records().length} records</span>
        </div>
        <p class="muted small">Paste or drop a TrainingRecord, a TrainingRecord array, or a monthly log JSON file.</p>
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
          Drop a .json log here, or paste below
        </div>
        <textarea spellcheck={false} placeholder={sampleMonth} value={text()} onInput={(e) => setText(e.target.value)} />
        <div class="row">
          <button onClick={preview}>Preview records</button>
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
            const parsedRecords = outcome().records || [];
            return (
              <div class="card">
                <div class="card-head">
                  <h4>Parsed {parsedRecords.length} training records</h4>
                  <button onClick={() => accept(parsedRecords)}>Merge records</button>
                </div>
                <RecordList records={parsedRecords.slice(0, 40)} />
              </div>
            );
          })()}
        </Show>
      </Show>

      <div class="card">
        <div class="card-head">
          <h3>Current timeline</h3>
          <button class="ghost" onClick={() => setText(JSON.stringify(records(), null, 2))}>Load as JSON</button>
        </div>
        <Show when={records().length} fallback={<p class="muted small">No training records yet.</p>}>
          <RecordList records={records()} />
        </Show>
      </div>
    </div>
  );
}

function RecordList(props) {
  return (
    <div class="timeline import-preview">
      <For each={props.records}>
        {(day) => (
          <div class="import-row">
            <div class="import-main">
              <strong>{day.date}</strong>
              <span class="muted small">{day.program || "workout"}</span>
            </div>
            <span class="muted small">{(day.lifts || []).length} lifts</span>
            <span class="import-detail">{recordDetail(day)}</span>
          </div>
        )}
      </For>
    </div>
  );
}
