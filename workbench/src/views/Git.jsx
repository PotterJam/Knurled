import { For, Show, createSignal } from "solid-js";
import { workbench } from "../workbench.js";
import { titleCase } from "../lib/format.js";

const THEMES = ["sage", "steel", "brass", "violet"];

export default function Git() {
  const g = () => workbench.state.github;
  const status = () => workbench.build().result?.validation?.status;

  // Local form mirrors of the persisted github config.
  const [token, setToken] = createSignal(g().token);
  const [repo, setRepo] = createSignal(g().repo);
  const [branch, setBranch] = createSignal(g().branch || "main");
  // { kind, body } feedback for connect/load/commit
  const [feedback, setFeedback] = createSignal(null);

  const formGithub = () => ({ token: token().trim(), repo: repo().trim(), branch: branch().trim() || "main" });
  const canCommit = () => Boolean(token().trim() && repo().trim() && status() === "valid");
  const save = () => workbench.setState({ github: formGithub() });

  const connect = async () => {
    setFeedback({ kind: "muted", body: "Connecting…" });
    try {
      await workbench.github.connect(formGithub());
      save();
      setFeedback(null);
    } catch (e) {
      setFeedback({ kind: "bad", body: e.message });
    }
  };
  const load = async () => {
    setFeedback({ kind: "muted", body: "Loading repo…" });
    try {
      await workbench.github.load(formGithub());
      workbench.setView("editor");
    } catch (e) {
      setFeedback({ kind: "bad", body: e.message });
    }
  };
  const clearToken = () => {
    setToken("");
    workbench.setState({ github: { ...workbench.state.github, token: "" } });
  };
  const commit = async () => {
    if (status() !== "valid") {
      setFeedback({ kind: "bad", body: "Plan is not valid — fix validation before committing." });
      return;
    }
    setFeedback({ kind: "muted", body: "Committing…" });
    try {
      const res = await workbench.github.commit(formGithub());
      setFeedback({ kind: "commit", res });
    } catch (e) {
      setFeedback({ kind: "bad", body: e.message });
    }
  };

  const setTheme = (t) => {
    document.documentElement.dataset.theme = t;
    workbench.setState({ theme: t });
  };

  return (
    <div class="stack">
      <div class="card">
        <div class="card-head">
          <h3>GitHub</h3>
          <Show when={workbench.githubUser()}>
            <span class="pill ok">@{workbench.githubUser()}</span>
          </Show>
        </div>
        <p class="muted small">Fine-grained PAT, stored only in this browser. Never sent to any server but GitHub.</p>
        <div class="form stack">
          <label>
            Token
            <input
              type="password"
              placeholder="github_pat_…"
              value={token()}
              onInput={(e) => setToken(e.target.value)}
              onChange={save}
            />
          </label>
          <div class="row">
            <label>
              Repo
              <input
                placeholder="owner/name"
                value={repo()}
                onInput={(e) => setRepo(e.target.value)}
                onChange={save}
              />
            </label>
            <label>
              Branch
              <input
                style="width:120px"
                value={branch()}
                onInput={(e) => setBranch(e.target.value)}
                onChange={save}
              />
            </label>
          </div>
          <div class="row">
            <button onClick={connect}>Connect</button>
            <button class="ghost" onClick={load}>Load repo</button>
            <button class="ghost" onClick={clearToken}>Clear token</button>
          </div>
        </div>
      </div>

      <div class="card">
        <div class="card-head">
          <h3>Commit</h3>
          <button disabled={!canCommit()} onClick={commit}>Commit changes</button>
        </div>
        <p class="muted small">
          Writes one atomic Git commit: plan.fitspec, fitspec.lock, state/current.json, build/*.json, active patches,
          and imported logs. Blocked unless valid.
        </p>
        <Show when={feedback()}>
          <Show
            when={feedback().kind === "commit"}
            fallback={
              <p class={feedback().kind === "muted" ? "muted" : `msg ${feedback().kind}`}>{feedback().body}</p>
            }
          >
            {(() => {
              const res = feedback().res;
              if (res.skipped) return <p class="msg ok">{res.message || "No changes to commit."}</p>;
              const shortSha = res.commitSha ? res.commitSha.slice(0, 7) : "";
              return (
                <>
                  <p class="msg ok">
                    Committed {res.committed} paths
                    <Show when={shortSha}>
                      {" "}
                      at{" "}
                      <a href={res.htmlUrl} target="_blank" rel="noreferrer">
                        {shortSha}
                      </a>
                    </Show>
                    .
                  </p>
                  <pre class="patch-text">{(res.changedFiles || []).join("\n")}</pre>
                </>
              );
            })()}
          </Show>
        </Show>
      </div>

      <div class="card">
        <h3>Appearance</h3>
        <div class="themes">
          <For each={THEMES}>
            {(t) => (
              <button
                class="theme-chip"
                classList={{ active: workbench.state.theme === t }}
                onClick={() => setTheme(t)}
              >
                <span class={`sw sw-${t}`}></span>
                {titleCase(t)}
              </button>
            )}
          </For>
        </div>
      </div>
    </div>
  );
}
