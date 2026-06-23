const samplePlan = `plan "James GZCLP" {
  template "gzcl.p@1.0.0"
  units kg

  schedule next_workout {
    rotation A1, B1, A2, B2
    suggested_days mon, wed, fri
  }

  starts {
    squat 80kg
    bench 55kg
    press 37.5kg
    deadlift 100kg
  }

  accessories {
    A1.T3 lat_pulldown
    B1.T3 barbell_row
    A2.T3 lat_pulldown
    B2.T3 barbell_row
  }
}
`;

const editor = document.querySelector("#plan-editor");
const output = document.querySelector("#output");
const statusValue = document.querySelector("#status-value");
const planValue = document.querySelector("#plan-value");
const templateValue = document.querySelector("#template-value");
const nextValue = document.querySelector("#next-value");
let activeOutput = "next";

editor.value = localStorage.getItem("knurled.plan") || samplePlan;

document.querySelector("#reset-sample").addEventListener("click", () => {
  editor.value = samplePlan;
  localStorage.setItem("knurled.plan", editor.value);
  render();
});

editor.addEventListener("input", () => {
  localStorage.setItem("knurled.plan", editor.value);
  render();
});

document.querySelector("#validate-button").addEventListener("click", () => {
  activeOutput = "validation";
  activateTab();
  render();
});

document.querySelector("#preview-button").addEventListener("click", () => {
  activeOutput = "next";
  activateTab();
  render();
});

document.querySelector("#simulate-button").addEventListener("click", () => {
  activeOutput = "simulation";
  activateTab();
  render();
});

document.querySelectorAll(".tab").forEach((button) => {
  button.addEventListener("click", () => {
    activeOutput = button.dataset.output;
    activateTab();
    render();
  });
});

document.querySelectorAll(".nav-item").forEach((button) => {
  button.addEventListener("click", () => {
    document.querySelectorAll(".nav-item").forEach((item) => item.classList.remove("active"));
    button.classList.add("active");
    const view = button.dataset.view;
    activeOutput = view === "plan" ? "validation" : view === "patches" ? "git" : view === "simulation" ? "simulation" : "next";
    activateTab();
    render();
  });
});

render();

function render() {
  const model = parsePlan(editor.value);
  const validation = validate(model);
  statusValue.textContent = validation.errors.length ? "Invalid" : "Valid";
  statusValue.className = validation.errors.length ? "bad" : "ok";
  planValue.textContent = model.name;
  templateValue.textContent = model.template;
  nextValue.textContent = model.rotation[0] || "A1";

  if (activeOutput === "validation") {
    renderValidation(validation);
  } else if (activeOutput === "simulation") {
    renderSimulation(model);
  } else if (activeOutput === "git") {
    renderGit(model, validation);
  } else {
    renderNext(model);
  }
}

function activateTab() {
  document.querySelectorAll(".tab").forEach((tab) => {
    tab.classList.toggle("active", tab.dataset.output === activeOutput);
  });
}

function parsePlan(text) {
  const name = text.match(/plan\s+"([^"]+)"/)?.[1] || "Untitled Plan";
  const template = text.match(/template\s+"([^"]+)"/)?.[1] || "gzcl.p@1.0.0";
  const units = text.match(/\bunits\s+(kg|lb)\b/i)?.[1] || "kg";
  const rotation = parseList(text.match(/rotation\s+([^\n]+)/)?.[1] || "A1, B1, A2, B2");
  const starts = parseBlockMap(text, "starts");
  const accessories = parseBlockMap(text, "accessories");

  return {
    name,
    template,
    units,
    rotation,
    starts,
    accessories
  };
}

function validate(model) {
  const errors = [];
  const warnings = [];
  const gzclp = model.template.startsWith("gzcl.");

  if (!model.name) {
    errors.push("Plan name is missing.");
  }

  if (gzclp) {
    for (const lift of ["squat", "bench", "press", "deadlift"]) {
      if (!model.starts[lift]) {
        errors.push(`Missing start load for ${lift}.`);
      }
    }
  }

  if (!model.template.includes("@")) {
    warnings.push("Template should include an explicit version.");
  }

  return { errors, warnings };
}

function renderNext(model) {
  const session = (model.rotation[0] || "A1").toUpperCase();
  const items = session === "A1"
    ? [
        ["Squat T1", `${model.starts.squat || "80kg"} - 5 / 5 / 5+`, "increase load on pass"],
        ["Bench T2", `${scale(model.starts.bench || "55kg", 0.8)} - 3x10`, "advance to 3x8 on fail"],
        [title(model.accessories["A1.T3"] || "lat_pulldown"), "3x15+", "history lane only"]
      ]
    : [["Session", session, "Run the CLI for full template rendering."]];

  output.innerHTML = `<div class="workout-list">${items.map(([name, detail, effect]) => `
    <article class="workout-item">
      <h3>${escapeHtml(name)}</h3>
      <p>${escapeHtml(detail)} · ${escapeHtml(effect)}</p>
    </article>
  `).join("")}</div>`;
}

function renderValidation(validation) {
  const messages = [
    ...validation.errors.map((message) => ["bad", message]),
    ...validation.warnings.map((message) => ["warn", message])
  ];

  output.innerHTML = messages.length
    ? `<div class="message-list">${messages.map(([kind, message]) => `<article class="message"><p class="${kind}">${escapeHtml(message)}</p></article>`).join("")}</div>`
    : `<article class="message"><p class="ok">Plan syntax and MVP template inputs look valid.</p></article>`;
}

function renderSimulation(model) {
  const squatStart = numericLoad(model.starts.squat || "80kg");
  const rows = Array.from({ length: 8 }, (_, index) => {
    const week = index + 1;
    const squat = `${squatStart + week * 7.5}${model.units}`;
    return `<article class="sim-row"><strong>Week ${week}</strong><p>Projected squat T1: ${squat}; cursor rotates through ${model.rotation.join(", ").toUpperCase()}.</p></article>`;
  });
  output.innerHTML = `<div class="sim-list">${rows.join("")}</div>`;
}

function renderGit(model, validation) {
  const files = [
    "plan.fitspec",
    "fitspec.lock",
    "state/current.json",
    "build/current.ir.json",
    "build/next-workout.json",
    "build/validation.json"
  ];
  output.innerHTML = `<pre>Status: ${validation.errors.length ? "blocked" : "ready"}
Plan: ${model.name}

Changed files after save/build:
${files.map((file) => `- ${file}`).join("\n")}

Suggested commit:
Update ${model.template.split("@")[0]} plan basics</pre>`;
}

function parseList(value) {
  return value.split(/[,\s]+/).map((item) => item.trim()).filter(Boolean);
}

function parseBlockMap(text, name) {
  const start = text.search(new RegExp(`\\b${name}\\s*\\{`));
  if (start === -1) {
    return {};
  }
  const open = text.indexOf("{", start);
  const close = text.indexOf("}", open);
  const block = text.slice(open + 1, close);
  return Object.fromEntries(block.split(/\n/).map((line) => {
    const match = line.trim().match(/^([A-Za-z0-9_.-]+)\s+(.+)$/);
    return match ? [match[1], match[2].trim()] : null;
  }).filter(Boolean));
}

function numericLoad(load) {
  return Number(String(load).match(/[0-9.]+/)?.[0] || 0);
}

function scale(load, multiplier) {
  const unit = String(load).match(/[a-z]+$/i)?.[0] || "kg";
  const value = Math.round((numericLoad(load) * multiplier) / 2.5) * 2.5;
  return `${value}${unit}`;
}

function title(value) {
  return String(value).split("_").map((part) => part.charAt(0).toUpperCase() + part.slice(1)).join(" ");
}

function escapeHtml(value) {
  return String(value)
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;");
}
