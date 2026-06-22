import Foundation

enum KnurledCoding {
    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }

    static func encoder(pretty: Bool = false) -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        var formatting: JSONEncoder.OutputFormatting = [.withoutEscapingSlashes]
        if pretty { formatting.insert(.prettyPrinted); formatting.insert(.sortedKeys) }
        encoder.outputFormatting = formatting
        return encoder
    }
}

struct EngineEnvelope<Payload: Decodable>: Decodable {
    let ok: Bool
    let data: Payload?
    let error: String?
}
