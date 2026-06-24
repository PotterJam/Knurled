import SwiftUI

struct DataHomeView: View {
    @Environment(AppModel.self) private var app
    @Environment(BodyMetricsStore.self) private var metrics

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: KnurledTheme.Spacing.m) {
                    BodyMetricsCard()
                    content
                }
                .padding()
            }
            .navigationTitle("Data")
        }
    }

    private var units: Units { app.activeRepo?.plan?.plan.units ?? .kg }

    private var progress: LiftProgressData {
        guard let repo = app.activeRepo else { return LiftProgressData(samples: []) }
        return LiftProgressData.build(events: repo.events, state: repo.state, units: units)
    }

    @ViewBuilder private var content: some View {
        if let bodyWeightKg = metrics.bodyWeightKg {
            let data = progress
            if data.isEmpty {
                ContentUnavailableView {
                    Label("No lift data yet", systemImage: "chart.xyaxis.line")
                } description: {
                    Text("Log a squat, bench, deadlift, or press to chart your strength levels.")
                }
            } else {
                StrengthLevelChart(data: data, bodyWeightKg: bodyWeightKg, sex: metrics.sex)
                    .knurledCard()
            }
        } else {
            ContentUnavailableView {
                Label("Add your body weight", systemImage: "scalemass")
            } description: {
                Text("Your body weight normalises each lift against strength standards.")
            }
        }
    }
}

/// Body weight, unit, and sex inputs. These are iOS-only (UserDefaults) and feed
/// the strength-level normalisation; they are never written to the repo or log.
private struct BodyMetricsCard: View {
    @Environment(BodyMetricsStore.self) private var metrics
    @State private var weightText = ""

    var body: some View {
        @Bindable var metrics = metrics
        VStack(alignment: .leading, spacing: KnurledTheme.Spacing.s) {
            Text("Body weight")
                .font(.headline)

            HStack(spacing: KnurledTheme.Spacing.s) {
                TextField("Weight", text: $weightText)
                    .keyboardType(.decimalPad)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: weightText) { _, new in
                        metrics.bodyWeight = Double(new.replacingOccurrences(of: ",", with: "."))
                    }

                Picker("Unit", selection: $metrics.unit) {
                    Text("kg").tag(Units.kg)
                    Text("lb").tag(Units.lb)
                }
                .pickerStyle(.segmented)
                .frame(width: 110)
            }

            Picker("Sex", selection: $metrics.sex) {
                ForEach(Sex.allCases) { sex in
                    Text(sex.title).tag(sex)
                }
            }
            .pickerStyle(.segmented)
        }
        .knurledCard()
        .onAppear {
            if weightText.isEmpty, let bodyWeight = metrics.bodyWeight {
                weightText = bodyWeight.formatted(.number.precision(.fractionLength(0...1)))
            }
        }
    }
}
