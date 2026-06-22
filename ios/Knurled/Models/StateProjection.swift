import Foundation

struct StateProjection: Codable, Sendable, Hashable {
    var type: String
    var schemaVersion: String
    var engineVersion: String
    var programHash: String
    var lastEventId: String?
    var cursor: Cursor
    var lanes: [String: LaneState]
    var sessions: [String: SessionState]
}

struct Cursor: Codable, Sendable, Hashable {
    var nextSession: String
    var week: Int
    var cycle: Int
}

struct LaneState: Codable, Sendable, Hashable {
    var load: String?
    var stage: String?
    var trainingMax: String?
    var week: Int?
    var cycle: Int?
}

struct SessionState: Codable, Sendable, Hashable {
    var status: String
    var sourceEvents: [String]
}
