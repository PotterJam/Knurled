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
    var previousLanes: [String: LaneCheckpoint]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decode(String.self, forKey: .type)
        schemaVersion = try container.decode(String.self, forKey: .schemaVersion)
        engineVersion = try container.decode(String.self, forKey: .engineVersion)
        programHash = try container.decode(String.self, forKey: .programHash)
        lastEventId = try container.decodeIfPresent(String.self, forKey: .lastEventId)
        cursor = try container.decode(Cursor.self, forKey: .cursor)
        lanes = try container.decode([String: LaneState].self, forKey: .lanes)
        sessions = try container.decode([String: SessionState].self, forKey: .sessions)
        previousLanes = try container.decodeIfPresent([String: LaneCheckpoint].self, forKey: .previousLanes) ?? [:]
    }
}

struct LaneCheckpoint: Codable, Sendable, Hashable {
    var recordId: String
    var previousState: LaneState
    var item: RenderedItem
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
    var reps: Int?
    var stall: Int?
}

struct SessionState: Codable, Sendable, Hashable {
    var status: String
    var sourceEvents: [String]
}
