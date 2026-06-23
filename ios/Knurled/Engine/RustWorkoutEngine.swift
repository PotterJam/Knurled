import Foundation
import KnurledCoreFFI

actor RustWorkoutEngine: WorkoutEngine {
    func engineVersion() throws -> String {
        let raw = try call { knurled_engine_version() }
        return try decode(String.self, from: raw)
    }

    func validate(dir: URL) throws -> ValidationReport {
        let raw = try call(dir: dir) { knurled_validate_repo($0) }
        return try decode(ValidationReport.self, from: raw)
    }

    func build(dir: URL, write: Bool) throws -> BuildOutputs {
        let raw = try call(dir: dir) { knurled_build_repo($0, write ? 1 : 0) }
        return try decode(BuildOutputs.self, from: raw)
    }

    func validateInput(dir: URL, input: ExecutionInput) throws -> ExecutionInputValidation {
        let json = try encode(input)
        let raw = try call(dir: dir, json: json) { knurled_validate_execution_input($0, $1) }
        return try decode(ExecutionInputValidation.self, from: raw)
    }

    func reduce(dir: URL, session: RenderedSession, input: ExecutionInput) throws -> ReductionOutcome {
        let sessionJSON = try encode(session)
        let inputJSON = try encode(input)
        let raw = try call(dir: dir, json1: sessionJSON, json2: inputJSON) { knurled_reduce_input($0, $1, $2) }
        let result = try decode(ReductionResult.self, from: raw)
        return ReductionOutcome(result: result, eventLine: Self.extractEventLine(from: raw))
    }

    // MARK: - FFI marshaling

    private func call(_ body: () -> UnsafeMutablePointer<CChar>?) throws -> String {
        guard let pointer = body() else { throw EngineError.emptyResponse }
        defer { knurled_string_free(pointer) }
        return String(cString: pointer)
    }

    private func call(
        dir: URL,
        _ body: (UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>?
    ) throws -> String {
        try dir.path(percentEncoded: false).withCString { cdir in
            guard let pointer = body(cdir) else { throw EngineError.emptyResponse }
            defer { knurled_string_free(pointer) }
            return String(cString: pointer)
        }
    }

    private func call(
        dir: URL,
        json: String,
        _ body: (UnsafePointer<CChar>, UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>?
    ) throws -> String {
        try dir.path(percentEncoded: false).withCString { cdir in
            try json.withCString { cjson in
                guard let pointer = body(cdir, cjson) else { throw EngineError.emptyResponse }
                defer { knurled_string_free(pointer) }
                return String(cString: pointer)
            }
        }
    }

    private func call(
        dir: URL,
        json1: String,
        json2: String,
        _ body: (UnsafePointer<CChar>, UnsafePointer<CChar>, UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>?
    ) throws -> String {
        try dir.path(percentEncoded: false).withCString { cdir in
            try json1.withCString { cjson1 in
                try json2.withCString { cjson2 in
                    guard let pointer = body(cdir, cjson1, cjson2) else { throw EngineError.emptyResponse }
                    defer { knurled_string_free(pointer) }
                    return String(cString: pointer)
                }
            }
        }
    }

    private func encode<T: Encodable>(_ value: T) throws -> String {
        let data = try KnurledCoding.encoder().encode(value)
        return String(decoding: data, as: UTF8.self)
    }

    private func decode<T: Decodable>(_ type: T.Type, from raw: String) throws -> T {
        let envelope = try KnurledCoding.decoder().decode(
            EngineEnvelope<T>.self,
            from: Data(raw.utf8)
        )
        if !envelope.ok {
            throw EngineError.engine(envelope.error ?? "unknown engine error")
        }
        guard let payload = envelope.data else { throw EngineError.missingData }
        return payload
    }

    private static func extractEventLine(from raw: String) -> String? {
        guard
            let object = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any],
            let data = object["data"] as? [String: Any],
            let event = data["event"], !(event is NSNull),
            let line = try? JSONSerialization.data(
                withJSONObject: event,
                options: [.withoutEscapingSlashes]
            )
        else { return nil }
        return String(decoding: line, as: UTF8.self)
    }
}
