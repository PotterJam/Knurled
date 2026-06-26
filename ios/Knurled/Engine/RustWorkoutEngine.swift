import Foundation
import KnurledCoreFFI

actor RustWorkoutEngine: WorkoutEngine {
    func engineVersion() throws -> String {
        let raw = try call { knurled_engine_version() }
        return try decode(String.self, from: raw)
    }

    func builtinTemplates() throws -> [StarterTemplate] {
        let raw = try call { knurled_builtin_templates() }
        return try decode([StarterTemplate].self, from: raw)
    }

    func exerciseCatalog() throws -> [ExerciseCatalogEntry] {
        let raw = try call { knurled_exercise_catalog() }
        return try decode([ExerciseCatalogEntry].self, from: raw)
    }

    func initRepo(dir: URL, template: String) throws {
        let raw = try call(dir: dir, json: template) { knurled_init_repo($0, $1) }
        _ = try decode(JSONValue.self, from: raw)
    }

    func validate(dir: URL) throws -> ValidationReport {
        let raw = try call(dir: dir) { knurled_validate_repo($0) }
        return try decode(ValidationReport.self, from: raw)
    }

    func build(dir: URL, write: Bool) throws -> BuildOutputs {
        let raw = try call(dir: dir) { knurled_build_repo($0, write ? 1 : 0) }
        return try decode(BuildOutputs.self, from: raw)
    }

    func renderSession(dir: URL, sessionId: String) throws -> RenderedSession {
        let raw = try call(dir: dir, json: sessionId) { knurled_render_session($0, $1) }
        return try decode(RenderedSession.self, from: raw)
    }

    func validateInput(dir: URL, input: ExecutionInput) throws -> ExecutionInputValidation {
        let json = try encode(input)
        let raw = try call(dir: dir, json: json) { knurled_validate_execution_input($0, $1) }
        return try decode(ExecutionInputValidation.self, from: raw)
    }

    func previewPlanEdit(dir: URL, edit: PlanEdit) throws -> PlanEditOutcome {
        let json = try encode(edit)
        let raw = try call(dir: dir, json: json) { knurled_preview_plan_edit($0, $1) }
        return try decode(PlanEditOutcome.self, from: raw)
    }

    func applyPlanEdit(dir: URL, edit: PlanEdit) throws -> PlanEditOutcome {
        let json = try encode(edit)
        let raw = try call(dir: dir, json: json) { knurled_apply_plan_edit($0, $1) }
        return try decode(PlanEditOutcome.self, from: raw)
    }

    func suggestInitialNumbers(dir: URL, request: InitialNumberSuggestionRequest) throws -> InitialNumberSuggestions {
        let json = try encode(request)
        let raw = try call(dir: dir, json: json) { knurled_suggest_initial_numbers($0, $1) }
        return try decode(InitialNumberSuggestions.self, from: raw)
    }

    func reduce(dir: URL, session: RenderedSession, input: ExecutionInput) throws -> ReductionResult {
        let sessionJSON = try encode(session)
        let inputJSON = try encode(input)
        let raw = try call(dir: dir, json1: sessionJSON, json2: inputJSON) { knurled_reduce_input($0, $1, $2) }
        return try decode(ReductionResult.self, from: raw)
    }

    func submit(
        dir: URL,
        session: RenderedSession,
        input: ExecutionInput,
        mode: SubmitMode,
        date: String
    ) throws -> SubmitOutcome {
        let sessionJSON = try encode(session)
        let inputJSON = try encode(input)
        let raw = try call(
            dir: dir,
            json1: sessionJSON,
            json2: inputJSON,
            json3: mode.rawValue,
            json4: date
        ) { knurled_submit($0, $1, $2, $3, $4) }
        return try decode(SubmitOutcome.self, from: raw)
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

    private func call(
        dir: URL,
        json1: String,
        json2: String,
        json3: String,
        json4: String,
        _ body: (
            UnsafePointer<CChar>,
            UnsafePointer<CChar>,
            UnsafePointer<CChar>,
            UnsafePointer<CChar>,
            UnsafePointer<CChar>
        ) -> UnsafeMutablePointer<CChar>?
    ) throws -> String {
        try dir.path(percentEncoded: false).withCString { cdir in
            try json1.withCString { cjson1 in
                try json2.withCString { cjson2 in
                    try json3.withCString { cjson3 in
                        try json4.withCString { cjson4 in
                            guard let pointer = body(cdir, cjson1, cjson2, cjson3, cjson4) else {
                                throw EngineError.emptyResponse
                            }
                            defer { knurled_string_free(pointer) }
                            return String(cString: pointer)
                        }
                    }
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

}
