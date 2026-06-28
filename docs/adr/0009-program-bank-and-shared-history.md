# ADR 0009 — Program bank with one active program and shared history

- Status: Accepted
- Date: 2026-06-28

## Context

Switching templates previously rewrote the single plan and discarded its progression state.
Users need several programs available without treating each as a separate training history.

## Decision

A repository contains multiple programs under `programs/<slug>/`, each with its own plan,
lockfile, patches, templates, and authored state. `fitspec.toml` lists the bank and points to one
active slug. Repository-level `logs/` are shared, giving the lifter one continuous history;
`build/` is regenerated from the active program.

All build, render, submit, reduce, validation, and plan-edit entry points resolve the active
program inside the engine. Clients continue to pass only the repository root. Changing the active
pointer never resets either program's state.

Legacy root-layout repositories are one implicit program. Reads remain compatible; the first
program-bank write moves program-owned files into the new layout.

## Consequences

- Switching programs preserves each program's progression.
- History and load suggestions operate globally across programs.
- Program deletion cannot delete the only remaining program.
- Generated files describe only the active program and may be replaced on every switch.
