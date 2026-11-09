import Foundation

/// A tool failure the agent should see as text (`isError: true`), not a protocol error.
struct MCPToolError: Error {
    let message: String
    init(_ message: String) { self.message = message }
}

/// JSON helpers for tools: Codable values go through `JSONSerialization` objects so they can be merged and returned.
enum MCPJSON {
    static func object<T: Encodable>(_ value: T) throws -> Any {
        let data = try JSONEncoder().encode(value)
        return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    static func decode<T: Decodable>(_ type: T.Type, from object: Any) throws -> T {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.fragmentsAllowed])
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch let DecodingError.typeMismatch(_, context), let DecodingError.valueNotFound(_, context) {
            throw MCPToolError("Invalid value at \(path(context.codingPath)): \(context.debugDescription)")
        } catch let DecodingError.keyNotFound(key, context) {
            throw MCPToolError("Missing \(path(context.codingPath + [key]))")
        } catch let DecodingError.dataCorrupted(context) {
            throw MCPToolError("Invalid value at \(path(context.codingPath)): \(context.debugDescription)")
        }
    }

    private static func path(_ keys: [CodingKey]) -> String {
        keys.isEmpty ? "root" : keys.map { $0.intValue.map { "[\($0)]" } ?? $0.stringValue }.joined(separator: ".")
    }

    /// RFC 7386: objects merge key by key, `null` removes a key, anything else replaces the target.
    static func mergePatch(_ target: Any?, _ patch: Any) -> Any {
        guard let patchObject = patch as? [String: Any] else { return patch }
        var result = (target as? [String: Any]) ?? [:]
        for (key, value) in patchObject {
            if value is NSNull {
                result[key] = nil
            } else {
                result[key] = mergePatch(result[key], value)
            }
        }
        return result
    }

    /// Applies a merge patch to a Codable value and decodes it back, so a bad patch fails before anything changes.
    static func patched<T: Codable>(_ value: T, with patch: Any) throws -> T {
        try decode(T.self, from: mergePatch(try object(value), patch))
    }

    static func text(_ object: Any) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        else { return "\(object)" }
        return String(decoding: data, as: UTF8.self)
    }
}

/// Typed reads of tool arguments.
struct MCPArguments {
    let raw: [String: Any]

    func string(_ key: String) -> String? {
        (raw[key] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    func requiredString(_ key: String) throws -> String {
        guard let value = string(key) else { throw MCPToolError("Missing argument: \(key)") }
        return value
    }

    func double(_ key: String) -> Double? {
        (raw[key] as? NSNumber)?.doubleValue
    }

    func requiredDouble(_ key: String) throws -> Double {
        guard let value = double(key) else { throw MCPToolError("Missing argument: \(key)") }
        return value
    }

    func int(_ key: String) -> Int? {
        (raw[key] as? NSNumber)?.intValue
    }

    func bool(_ key: String) -> Bool? {
        (raw[key] as? NSNumber)?.boolValue
    }

    func object(_ key: String) -> [String: Any]? {
        raw[key] as? [String: Any]
    }

    func has(_ key: String) -> Bool {
        raw[key] != nil
    }

    /// `true` when the key is present and set to JSON `null`.
    func isNull(_ key: String) -> Bool {
        raw[key] is NSNull
    }
}
