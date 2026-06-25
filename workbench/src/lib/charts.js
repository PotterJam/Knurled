// Tiny dependency-free inline-SVG charts — no charting library. Returns SVG
// markup as a string; views render it via `innerHTML`.

const NS = "http://www.w3.org/2000/svg";

function svg(w, h, children) {
  return `<svg viewBox="0 0 ${w} ${h}" width="100%" preserveAspectRatio="none" role="img" class="chart">${children}</svg>`;
}

// series: [{ label, color, points: number[] }]  (points share the x-axis index)
export function lineChart(series, { width = 640, height = 220, pad = 28 } = {}) {
  const all = series.flatMap((s) => s.points);
  if (!all.length) return svg(width, height, "");
  const max = Math.max(...all);
  const min = Math.min(...all);
  const span = max - min || 1;
  const n = Math.max(...series.map((s) => s.points.length), 1);
  const x = (i) => pad + (i * (width - pad * 2)) / Math.max(n - 1, 1);
  const y = (v) => height - pad - ((v - min) / span) * (height - pad * 2);

  const grid = [0, 0.5, 1]
    .map((t) => {
      const gy = pad + t * (height - pad * 2);
      const val = (max - t * span).toFixed(1);
      return `<line x1="${pad}" y1="${gy}" x2="${width - pad}" y2="${gy}" class="chart-grid"/><text x="2" y="${gy + 4}" class="chart-axis">${val}</text>`;
    })
    .join("");

  const paths = series
    .map((s) => {
      const d = s.points.map((p, i) => `${i === 0 ? "M" : "L"}${x(i).toFixed(1)},${y(p).toFixed(1)}`).join(" ");
      const dots = s.points.map((p, i) => `<circle cx="${x(i).toFixed(1)}" cy="${y(p).toFixed(1)}" r="2.5" fill="${s.color}"/>`).join("");
      return `<path d="${d}" fill="none" stroke="${s.color}" stroke-width="2"/>${dots}`;
    })
    .join("");

  return svg(width, height, grid + paths);
}

export function legend(series) {
  return `<div class="chart-legend">${series
    .map((s) => `<span><i style="background:${s.color}"></i>${s.label}</span>`)
    .join("")}</div>`;
}

void NS;
