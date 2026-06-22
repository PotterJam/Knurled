import SwiftUI

struct PlanHomeView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        NavigationStack {
            Group {
                if let repo = app.activeRepo, let plan = repo.plan {
                    PlanOverviewView(repo: repo, plan: plan)
                } else {
                    ContentUnavailableView(
                        "No Plan",
                        systemImage: "list.bullet.rectangle",
                        description: Text("Connect a repository to see your program.")
                    )
                }
            }
            .navigationTitle("Plan")
        }
    }
}

struct PlanOverviewView: View {
    let repo: ActiveRepo
    let plan: PlanIR

    private struct RotationRow: Identifiable {
        let id: String
        let label: String
        let isNext: Bool
    }

    var body: some View {
        List {
            Section {
                LabeledContent("Program", value: plan.plan.name)
                LabeledContent("Template", value: plan.plan.template)
                LabeledContent("Units", value: plan.plan.units.rawValue.uppercased())
                HStack {
                    Text("Status")
                    Spacer()
                    if repo.isValid {
                        StatusChip(text: "valid", style: .ok)
                    } else {
                        StatusChip(text: "invalid", style: .bad)
                    }
                }
            }

            Section("Rotation") {
                ForEach(rotationRows) { row in
                    HStack {
                        Text(row.id.uppercased())
                            .font(.body.monospaced())
                        Spacer()
                        Text(row.label)
                            .foregroundStyle(row.isNext ? Color.accentColor : .secondary)
                            .fontWeight(row.isNext ? .semibold : .regular)
                    }
                }
            }

            Section("Suggested days") {
                Text(plan.schedule.suggestedDays.map { $0.capitalized }.joined(separator: ", "))
            }

            if let validation = repo.validation, !validation.isValid {
                Section("Validation") {
                    ForEach(Array(validation.errors.enumerated()), id: \.offset) { _, message in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(message.code).font(.caption.monospaced()).foregroundStyle(.red)
                            Text(message.message).font(.callout)
                        }
                    }
                }
            }
        }
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
