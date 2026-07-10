import Foundation

public enum JSONValue: Codable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else if let o = try? c.decode([String: JSONValue].self) { self = .object(o) }
        else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "value is not JSON")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n): try c.encode(n)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }
}

public enum SkyErrorCode: String, Codable {
    case appNotFound = "app_not_found"
    case noFocusedWindow = "no_focused_window"
    case staleElementIndex = "stale_element_index"
    case elementNotActionable = "element_not_actionable"
    case permissionDenied = "permission_denied"
    case captureFailed = "capture_failed"
    case notImplemented = "not_implemented"
    case timeout = "timeout"
    case protocolError = "protocol_error"
    case unknownMethod = "unknown_method"
    case actuationPaused = "actuation_paused"
    case invalidParams = "invalid_params"
    case approvalRequired = "approval_required"
}

public struct SkyServiceError: Error {
    public let code: SkyErrorCode
    public let message: String
    public init(code: SkyErrorCode, message: String) {
        self.code = code
        self.message = message
    }
}

public struct Request: Codable, Equatable {
    public let id: Int
    public let method: String
    public let params: JSONValue?

    public init(id: Int, method: String, params: JSONValue? = nil) {
        self.id = id
        self.method = method
        self.params = params
    }

    public func decodeParams<T: Decodable>(_ type: T.Type) throws -> T {
        let data = try JSONEncoder().encode(params ?? .object([:]))
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw SkyServiceError(code: .invalidParams, message: "params for \(method): \(error)")
        }
    }
}

public struct ErrorPayload: Codable, Equatable {
    public let code: String
    public let message: String
    public init(code: SkyErrorCode, message: String) {
        self.code = code.rawValue
        self.message = message
    }
}

public struct Response: Codable, Equatable {
    public let id: Int
    public let ok: Bool
    public let result: JSONValue?
    public let error: ErrorPayload?

    public static func success<T: Encodable>(id: Int, result: T) throws -> Response {
        let data = try JSONEncoder().encode(result)
        let value = try JSONDecoder().decode(JSONValue.self, from: data)
        return Response(id: id, ok: true, result: value, error: nil)
    }

    public static func failure(id: Int, code: SkyErrorCode, message: String) -> Response {
        Response(id: id, ok: false, result: nil, error: ErrorPayload(code: code, message: message))
    }
}
