import Foundation

struct PlanIR: Codable, Sendable, Hashable {
    struct Identity: Codable, Sendable, Hashable {
        var name: String
        var template: String
        var templateId: String
        var templateVersion: String
        var units: Units
    }

    struct Schedule: Codable, Sendable, Hashable {
        var mode: String
        var rotation: [String]
        var suggestedDays: [String]
    }

    var plan: Identity
    var schedule: Schedule

    static func load(dir: URL) throws -> PlanIR {
        let url = dir.appending(path: "build/current.ir.json")
        return try KnurledCoding.decoder().decode(PlanIR.self, from: Data(contentsOf: url))
    }
}
