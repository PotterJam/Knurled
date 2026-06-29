import SwiftUI

/// The program overview, reached by tapping the program name on the Workout tab.
/// Pushed onto the caller's navigation stack (it does not create its own).
struct PlanOverviewView: View {
    let repo: ActiveRepo
    let plan: PlanIR

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: KnurledTheme.Spacing.m) {
                    PlanSummaryPanel(
                        repo: repo,
                        plan: plan,
                        suggestedDays: suggestedDaysText
                    )

                    if let validation = repo.validation, !validation.isValid {
                        ValidationPanel(validation: validation)
                    }
                }
                .padding()
            }

            VStack(alignment: .leading, spacing: KnurledTheme.Spacing.s) {
                Text("Edit")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)

                NavigationLink {
                    ProgramEditorView(repo: repo, plan: plan)
                } label: {
                    PlanActionRow(title: "Edit program", systemImage: "slider.horizontal.3")
                }
                NavigationLink {
                    ProgramBankView(repo: repo)
                } label: {
                    PlanActionRow(title: "Program bank", systemImage: "square.stack.3d.up")
                }
            }
            .padding()
            .background(.bar)
        }
    }

    private var suggestedDaysText: String {
        let days = plan.schedule.suggestedDays
        return days.isEmpty ? "None" : days.map { $0.capitalized }.joined(separator: ", ")
    }
}

private struct PlanSummaryPanel: View {
    let repo: ActiveRepo
    let plan: PlanIR
    let suggestedDays: String

    var body: some View {
        VStack(alignment: .leading, spacing: KnurledTheme.Spacing.m) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(plan.plan.name)
                        .font(.headline)
                    Text("\(plan.plan.template) · \(plan.plan.units.rawValue.uppercased())")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                StatusChip(text: repo.isValid ? "valid" : "invalid", style: repo.isValid ? .ok : .bad)
            }

            Divider()

            VStack(alignment: .leading, spacing: KnurledTheme.Spacing.s) {
                if !plan.schedule.rotation.isEmpty {
                    RotationIndicator(
                        rotation: plan.schedule.rotation,
                        currentSession: repo.state?.cursor.nextSession ?? ""
                    )
                }
                LabeledContent("Days", value: suggestedDays)
            }
            .font(.callout)
        }
        .knurledCard()
    }
}

private struct ValidationPanel: View {
    let validation: ValidationReport

    var body: some View {
        VStack(alignment: .leading, spacing: KnurledTheme.Spacing.s) {
            Label("Validation", systemImage: "exclamationmark.triangle")
                .font(.headline)
                .foregroundStyle(.red)

            ForEach(Array(validation.errors.enumerated()), id: \.offset) { _, message in
                VStack(alignment: .leading, spacing: 2) {
                    Text(message.code)
                        .font(.caption.monospaced())
                        .foregroundStyle(.red)
                    Text(message.message)
                        .font(.callout)
                }
            }
        }
        .knurledCard()
    }
}

private struct PlanActionRow: View {
    let title: String
    let systemImage: String

    var body: some View {
        HStack {
            Label(title, systemImage: systemImage)
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }
}
