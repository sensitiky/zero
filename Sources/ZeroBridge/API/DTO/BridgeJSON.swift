import Foundation

/// The one encoder and the one decoder the wire uses.
///
/// Centralised because `CONTRACT.md` is frozen and every deviation from it is a client bug that
/// looks like a server bug: a date written two ways, a slash escaped in one response and not in the
/// next. Sorted keys make a response byte-identical for the same value, which is what lets
/// `ProjectionTests` assert the literal JSON of the contract rather than a round-trip — a round-trip
/// cannot catch a renamed key that both sides of Swift agree on.
public enum BridgeJSON {
    public static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        // `.withoutEscapingSlashes` because a project id is a filesystem path, and
        // `\/Users\/…` is the contract's example written wrong.
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    public static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        try encoder.encode(value)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try decoder.decode(type, from: data)
    }
}

extension KeyedEncodingContainer {
    /// Writes `null` for a nil optional rather than omitting the key.
    ///
    /// Swift's synthesized encoder uses `encodeIfPresent` for optionals, so a nil field disappears
    /// from the object. CONTRACT.md writes those fields as `null` — `"error": null`,
    /// `"endedAt": null`, every field of `Usage` — and a client written against a key that is
    /// sometimes absent and sometimes null has to handle two shapes for one fact.
    mutating func encodeExplicit<T: Encodable>(_ value: T?, forKey key: Key) throws {
        if let value {
            try encode(value, forKey: key)
        } else {
            try encodeNil(forKey: key)
        }
    }
}
