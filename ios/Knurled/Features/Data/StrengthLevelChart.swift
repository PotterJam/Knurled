import SwiftUI
import Charts

/// Plots each core lift's estimated 1RM over time on a shared strength-level axis.
/// Every lift is normalised through its own (sex-specific) body-weight multiples,
/// so a lift sitting on the "Novice" line means the same thing for all four.
struct StrengthLevelChart: View {
    let data: LiftProgressData
    let bodyWeightKg: Double
    let sex: Sex

    private func level(_ sample: LiftSample) -> Double {
        StrengthStandards.levelValue(
            e1rmKg: sample.e1RMkg,
            bodyWeightKg: bodyWeightKg,
            lift: sample.lift,
            sex: sex
        )
    }

    private var maxY: Double {
        let top = data.samples.map(level).max() ?? 0
        let padded = top + 0.25
        return max(1.0, (padded * 2).rounded(.up) / 2)
    }

    private var visibleLevels: [StrengthLevel] {
        StrengthLevel.allCases.filter { Double($0.value) <= maxY }
    }

    private var xDomain: ClosedRange<Int> {
        let maxWorkout = data.workoutIndexes.max() ?? 1
        return maxWorkout > 1 ? 1...maxWorkout : 0...2
    }

    private static func color(for lift: CoreLift) -> Color {
        switch lift {
        case .squat: .blue
        case .bench: .orange
        case .deadlift: .red
        case .press: .green
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: KnurledTheme.Spacing.s) {
            Text("Strength level")
                .font(.headline)
            Text("Estimated 1RM mapped to \(sex.title.lowercased()) strength standards for your body weight.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Chart {
                ForEach(visibleLevels) { lvl in
                    RuleMark(y: .value("Level", lvl.value))
                        .lineStyle(StrokeStyle(lineWidth: 0.5, dash: [4, 4]))
                        .foregroundStyle(Color.secondary.opacity(0.35))
                        .annotation(position: .overlay, alignment: .leading) {
                            Text(lvl.title)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                }

                ForEach(data.samples) { sample in
                    LineMark(
                        x: .value("Workout", sample.workoutIndex),
                        y: .value("Level", level(sample))
                    )
                    .foregroundStyle(by: .value("Lift", sample.lift.title))
                    .symbol(by: .value("Lift", sample.lift.title))
                }

                ForEach(data.samples) { sample in
                    PointMark(
                        x: .value("Workout", sample.workoutIndex),
                        y: .value("Level", level(sample))
                    )
                    .foregroundStyle(by: .value("Lift", sample.lift.title))
                    .symbol(by: .value("Lift", sample.lift.title))
                }
            }
            .chartXScale(domain: xDomain)
            .chartXAxis {
                AxisMarks(values: data.workoutIndexes)
            }
            .chartYScale(domain: 0...maxY)
            .chartYAxis {
                AxisMarks(values: visibleLevels.map(\.value))
            }
            .chartForegroundStyleScale(
                domain: data.lifts.map(\.title),
                range: data.lifts.map(Self.color(for:))
            )
            .chartLegend(position: .bottom)
            .frame(height: 280)
            .clipped()
        }
    }
}
