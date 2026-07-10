import Foundation

public final class RequestRouter {
    public typealias MethodHandler = (Request) -> Response
    private var methods: [String: MethodHandler] = [:]

    public init() {}

    public func register(_ name: String, _ handler: @escaping MethodHandler) {
        methods[name] = handler
    }

    public func route(_ request: Request) -> Response {
        guard let handler = methods[request.method] else {
            return .failure(id: request.id, code: .unknownMethod, message: "unknown method '\(request.method)'")
        }
        return handler(request)
    }
}
