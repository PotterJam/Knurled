import SwiftUI

/// The program overview, reached by tapping the program name on the Workout tab.
/// Pushed onto the caller's navigation stack (it does not create its own).
struct PlanOverviewView: View {
    let repo: ActiveRepo
    let plan: PlanIR

    struct RotationRow: Identifiable {
        let id: String
        let label: String
        let isNext: Bool
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: KnurledTheme.Spacing.m) {
                    PlanSummaryPanel(
                        repo: repo,
                        plan: plan,
                        rotationRows: rotationRows,
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
                    QuickPlanEditView(repo: repo, plan: plan)
                } label: {
                    PlanActionRow(title: "Quick edits", systemImage: "slider.horizontal.3")
                }
                NavigationLink {
                    PatchPlanEditView(repo: repo)
                } label: {
                    PlanActionRow(title: "Add patch", systemImage: "bandage")
                }
                NavigationLink {
                    SwitchProgramView(repo: repo)
                } label: {
                    PlanActionRow(title: "Switch program", systemImage: "arrow.triangle.branch")
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

    private var rotationRows: [RotationRow] {
        let next = repo.state?.cursor.nextSession
        let rotation = plan.schedule.rotation
        guard let nextIndex = rotation.firstIndex(where: { $0 == next }) else {
            return rotation.map { RotationRow(id: $0, label: "", isNext: false) }
        }
        return rotation.enumerated().map { index, session in
            let label = index == nextIndex ? "Next" : (index < nextIndex ? "Done" : "Then")
            return RotationRow(id: session, label: label, isNext: index == nextIndex)
        }
    }
}

private struct PlanSummaryPanel: View {
    let repo: ActiveRepo
    let plan: PlanIR
    let rotationRows: [PlanOverviewView.RotationRow]
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
                LabeledContent("Rotation") {
                    Text(rotationText)
                        .font(.callout.monospaced())
                        .multilineTextAlignment(.trailing)
                }
                LabeledContent("Days", value: suggestedDays)
            }
            .font(.callout)
        }
        .knurledCard()
    }

    private var rotationText: String {
        rotationRows.map { row in
            row.isNext ? "\(row.id.uppercased()) next" : row.id.uppercased()
        }
        .joined(separator: "  ")
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
