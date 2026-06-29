import { For, Show, createSignal } from "solid-js";
import { workbench } from "../workbench.js";
import { titleCase } from "../lib/format.js";

function restLabel(seconds) {
  return `Rest ${Math.round(seconds / 60)}m ${seconds % 60 ? `${seconds % 60}s` : ""}`;
}

function today() {
  return new Date().toISOString().slice(0, 10);
}

function timestamp(date, hour) {
  return `${date}T${String(hour).padStart(2, "0")}:00:00Z`;
}

function inputForItem(item) {
  if (item.execution_contract?.recommended_input === "amrap_final_set") {
    const finalSet = item.prescription.sets.at(-1);
    return {
      item_id: item.item_id,
      mode: "amrap_final_set",
      final_set_reps: (finalSet?.target_reps || 0) + 2,
      sets: [],
      load: null,
      performed_exercise: null,
      swap_reason: null,
      swap_policy: null,
    };
  }

  return {
    item_id: item.item_id,
    mode: "per_set_reps",
    final_set_reps: null,
    sets: item.prescription.sets.map((set) => ({
      set: set.set,
      load: set.load || null,
      reps: set.target_reps,
      metrics: {},
    })),
    load: null,
    performed_exercise: null,
    swap_reason: null,
    swap_policy: null,
  };
}

function passingInput(session, date) {
  return {
    type: "execution_input",
    schema_version: session.schema_version,
    rendered_session_hash: session.rendered_session_hash,
    started_at: timestamp(date, 10),
    completed_at: timestamp(date, 11),
    inputs: session.items.map(inputForItem),
  };
}

export default function Next() {
  const build = () => workbench.build();
  const session = () => build().result?.next_workout;
  const [date, setDate] = createSignal(today());
  const [mode, setMode] = createSignal("advance");
  const [outcome, setOutcome] = createSignal(null);

  const submit = () => {
    try {
      setOutcome({ result: workbench.submit(passingInput(session(), date()), mode(), date()) });
    } catch (error) {
      setOutcome({ error: error.message });
    }
  };

  return (
    <Show
      when={session()}
      fallback={
        <div class="card">
          <p class="msg bad">{build().error || "Plan invalid — no session to render."}</p>
        </div>
      }
    >
      <div class="session-render">
        <div class="session-head">
          <h2>{session().display_name}</h2>
          <Show when={session().suggested_date}>
            <span class="muted">{session().suggested_date}</span>
          </Show>
        </div>
        <div class="card submit-panel">
          <div class="card-head">
            <h3>Submit session</h3>
            <button onClick={submit}>Submit passing result</button>
          </div>
          <div class="row">
            <label>Date <input type="date" value={date()} onInput={(e) => setDate(e.target.value)} /></label>
            <label>
              Mode
              <select value={mode()} onInput={(e) => setMode(e.target.value)}>
                <option value="advance">Advance</option>
                <option value="off_day">Off day</option>
                <option value="reset">Reset</option>
              </select>
            </label>
          </div>
          <Show when={outcome()}>
            <Show when={!outcome().error} fallback={<p class="msg bad">{outcome().error}</p>}>
              <p class={`msg ${outcome().result.validation?.status === "valid" ? "ok" : "bad"}`}>
                {outcome().result.validation?.status === "valid"
                  ? `Recorded ${outcome().result.record?.date}.`
                  : outcome().result.validation?.errors?.[0]?.message || "Submission was not valid."}
              </p>
            </Show>
          </Show>
        </div>
        <For each={session().items}>
          {(item) => (
            <article class="exercise-card">
              <header>
                <h3>{item.display?.title || titleCase(item.exercise)}</h3>
                <span class="lane">{item.progression_lane}</span>
              </header>
              <div class="sets">
                <For each={item.prescription.sets}>
                  {(s) => (
                    <div class="set">
                      <span class="set-n">{s.set}</span>
                      <span>{s.load || "—"}</span>
                      <span>
                        {s.target_reps ?? ""}
                        {s.amrap ? "+" : ""} reps
                      </span>
                    </div>
                  )}
                </For>
              </div>
              <Show when={item.rest?.seconds}>
                <p class="rest">{restLabel(item.rest.seconds)}</p>
              </Show>
            </article>
          )}
        </For>
      </div>
    </Show>
  );
}
