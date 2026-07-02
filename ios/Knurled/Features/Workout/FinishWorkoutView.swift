import SwiftUI

struct FinishWorkoutView: View {
    let workout: LiveWorkout
    var onCommitted: () -> Void

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    private enum Phase {
        case computing
        case preview(ReductionResult)
        case submitting
        case failed(String)
    }

    @State private var phase: Phase = .computing
    @State private var timestamp = LiveWorkout.timestamp()
    @State private var mode: SubmitMode = .advance
    @State private var showResetConfirm = false

    var body: some View {
        NavigationStack {
            Group {
                switch phase {
                case .computing:
                    ProgressView("Calculating effects…")
                case .preview(let outcome):
                    previewContent(outcome)
                case .submitting:
                    ProgressView("Saving…")
                case .failed(let message):
                    failedContent(message)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .navigationTitle("Finish \(workout.session.displayName)")
            .task { await compute() }
        }
    }

    private func previewContent(_ outcome: ReductionResult) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: KnurledTheme.Spacing.l) {
                // Reset rewrites every baseline, so it is never a peer segment next to Advance —
                // it is armed via an explicit confirmation and shown as a distinct banner.
                if mode == .reset {
                    resetArmedCard
                } else {
                    Picker("Submit mode", selection: $mode) {
                        ForEach([SubmitMode.advance, .offDay], id: \.self) { option in
                            Text(option.title).tag(option)
                        }
                    }
                    .pickerStyle(.segmented)

                    Text(mode.subtitle)
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    Text("Everything logged becomes this workout. With Advance, only exercises whose required sets are complete progress.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: KnurledTheme.Spacing.s) {
                    Text("Effects").font(.headline)
                    if mode == .advance {
                        ForEach(Array(outcome.results.enumerated()), id: \.offset) { _, result in
                            EffectResultRow(result: result, title: title(forSlot: result.slotId))
                        }
                        if outcome.results.isEmpty {
                            Text("No progression changes.").foregroundStyle(.secondary)
                        }
                    } else if mode == .offDay {
                        Text("No progression changes.").foregroundStyle(.secondary)
                    } else {
                        Text("Baselines will be reset from the performed loads.").foregroundStyle(.secondary)
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Next").font(.headline)
                    Text(outcome.nextWorkout.displayName)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Button {
                    Task { await submit(outcome) }
                } label: {
                    Label("Finish Workout", systemImage: "flag.checkered")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                if mode != .reset {
                    Button("Use today's loads as my new baselines…") {
                        showResetConfirm = true
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                }
            }
            .padding()
        }
        .confirmationDialog(
            "Reset baselines from today's loads?",
            isPresented: $showResetConfirm,
            titleVisibility: .visible
        ) {
            Button("Reset baselines", role: .destructive) { mode = .reset }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every exercise's progression baseline is rewritten to the load you performed today, and future workouts are prescribed from those new numbers. This can't be undone from the app.")
        }
    }

    private var resetArmedCard: some View {
        VStack(alignment: .leading, spacing: KnurledTheme.Spacing.s) {
            Label("Resetting baselines", systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.orange)

            Text(SubmitMode.reset.subtitle)
                .font(.footnote)
                .foregroundStyle(.secondary)

            Button("Switch back to Advance") { mode = .advance }
                .font(.footnote.weight(.medium))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(
            Color.orange.opacity(0.12),
            in: RoundedRectangle(cornerRadius: KnurledTheme.Radius.card, style: .continuous)
        )
    }

    /// A failed finish must never dead-end: the draft is intact, so the user can go back to the
    /// live workout to fix the problem, or simply retry after a transient failure.
    private func failedContent(_ message: String) -> some View {
        VStack(spacing: KnurledTheme.Spacing.l) {
            ContentUnavailableView {
                Label("Couldn't finish", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            }

            VStack(spacing: KnurledTheme.Spacing.s) {
                Button {
                    dismiss()
                } label: {
                    Label("Back to workout", systemImage: "chevron.left")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Button("Try again") {
                    phase = .computing
                    Task { await compute() }
                }

                Text("Nothing was lost — your sets are still logged. Adjust whatever needs fixing and finish again.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding([.horizontal, .bottom])
        }
    }

    private func title(forSlot slot: String) -> String {
        workout.session.items.first { $0.slotId == slot }?.display.title
            ?? WorkoutFormat.laneTitle(slot)
    }

    private func compute() async {
        guard case .computing = phase else { return }
        let input = workout.finishInput(timestamp: timestamp)
        do {
            let outcome = try await app.engine.reduce(dir: workout.repo.url, session: workout.session, input: input)
            if outcome.validation.isValid {
                phase = .preview(outcome)
            } else {
                let message = outcome.validation.errors.map(\.displayText).joined(separator: "\n")
                phase = .failed(message.isEmpty ? "The workout could not be validated." : message)
            }
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private func submit(_ outcome: ReductionResult) async {
        phase = .submitting
        do {
            let input = workout.finishInput(timestamp: timestamp)
            let submitted = try await app.submit(
                session: workout.session,
                input: input,
                mode: mode,
                in: workout.repo,
                timestamp: timestamp
            )
            guard submitted.validation.isValid else {
                let message = submitted.validation.errors.map(\.displayText).joined(separator: "\n")
                phase = .failed(message.isEmpty ? "The workout could not be submitted." : message)
                return
            }
            // End the live controller before the workout view disappears. Otherwise its teardown
            // save can recreate the draft that finishing just removed.
            WorkoutLiveController.shared.finish()
            onCommitted()
            dismiss()
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }
}

struct SavedResultRow: View {
    let result: ExerciseResult
    let title: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "tray.and.arrow.down.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.medium))
                Text("\(result.actual.count) \(result.actual.count == 1 ? "set" : "sets") logged")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }
}

struct EffectResultRow: View {
    let result: ExerciseResult
    let title: String

    private var symbol: (name: String, color: Color) {
        switch result.outcome {
        case "pass": ("checkmark.circle.fill", .green)
        case "fail": ("xmark.circle.fill", .red)
        case "adjusted_today": ("arrow.down.circle.fill", .orange)
        case "incomplete": ("circle.dashed", .secondary)
        default: ("circle", .secondary)
        }
    }

    private var emptyEffectText: String {
        switch result.outcome {
        case "adjusted_today": "Adjusted today · repeat next time"
        case "incomplete": "Not finished · no change"
        default: "No change"
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol.name)
                .foregroundStyle(symbol.color)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.medium))
                if result.effects.isEmpty {
                    Text(emptyEffectText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(result.effects.enumerated()), id: \.offset) { _, effect in
                        Text(WorkoutFormat.effectSummary(effect))
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Spacer()
        }
    }
}
