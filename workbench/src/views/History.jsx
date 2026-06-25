import { For, Show, createMemo, createSignal } from "solid-js";
import { workbench } from "../workbench.js";
import { titleCase } from "../lib/format.js";

function normalizeDays(value) {
  if (Array.isArray(value)) return value;
  if (Array.isArray(value?.days)) return value.days;
  if (value?.date) return [value];
  throw new Error("Paste a DayRecord, a DayRecord array, or a LogMonth with a days array.");
}

// A record's identity is its date *and* session (matching the engine's
// `upsert_day`): two sessions on one date are distinct, and re-importing a
// session replaces it in place.
function recordKey(day) {
  return `${day.date}#${day.session_id ?? ""}`;
}

function mergeRecords(existing, incoming) {
  const merged = [...(existing || [])];
  const indexByKey = new Map(merged.map((day, index) => [recordKey(day), index]));
  let added = 0;
  let replaced = 0;

  for (const day of incoming || []) {
    if (!day?.date) throw new Error("Every DayRecord needs a date.");
    const key = recordKey(day);
    if (indexByKey.has(key)) {
      merged[indexByKey.get(key)] = day;
      replaced++;
    } else {
      indexByKey.set(key, merged.length);
      merged.push(day);
      added++;
    }
  }

  merged.sort((a, b) => String(a.date || "").localeCompare(String(b.date || "")));
  return { records: merged, added, replaced };
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
    days: [{ date: "2026-06-24", lifts: [{ exercise: "squat", weight: "80kg", sets: [5, 5, 7] }] }],
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
      setOutcome({ days: normalizeDays(JSON.parse(text())) });
    } catch (err) {
      setOutcome({ error: err.message });
    }
  };

  const accept = (days) => {
    const merged = mergeRecords(records(), days);
    const historyNotice = {
      kind: "ok",
      title: "Records updated",
      message: `Added ${merged.added} day${merged.added === 1 ? "" : "s"} and replaced ${merged.replaced}.`,
    };
    workbench.setState({ records: merged.records, ui: { ...workbench.state.ui, historyNotice } });
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
          <span class="pill ok">{records().length} days</span>
        </div>
        <p class="muted small">Paste or drop a DayRecord, a DayRecord array, or a monthly log JSON file.</p>
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
            const days = outcome().days || [];
            return (
              <div class="card">
                <div class="card-head">
                  <h4>Parsed {days.length} day records</h4>
                  <button onClick={() => accept(days)}>Merge records</button>
                </div>
                <RecordList records={days.slice(0, 40)} />
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
        <Show when={records().length} fallback={<p class="muted small">No recorded days yet.</p>}>
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
