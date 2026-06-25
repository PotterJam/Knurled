// Shared presentation helpers. JSX auto-escapes text, so there is no HTML-escape
// helper here anymore — Solid handles that.

export const titleCase = (v) =>
  String(v)
    .split(/[_\s]+/)
    .map((p) => p.charAt(0).toUpperCase() + p.slice(1))
    .join(" ");

export const PALETTE = ["#618FEB", "#8CB587", "#D4A350", "#A378EB", "#cf6d6d", "#46b1a8"];
