import Foundation
import SkylightCore

let router = RequestRouter()
router.register("ping") { req in
    try! Response.success(
        id: req.id,
        result: JSONValue.object(["pong": .bool(true), "version": .string(SkylightVersion.current)])
    )
}
router.register("echo") { req in
    try! Response.success(id: req.id, result: req.params ?? JSONValue.object([:]))
}

let server = IPCServer(socketPath: SkylightPaths.socketPath, handler: router.route)
do {
    try server.start()
    FileHandle.standardError.write(Data("SkylightService \(SkylightVersion.current) listening at \(SkylightPaths.socketPath)\n".utf8))
} catch {
    FileHandle.standardError.write(Data("fatal: \(error)\n".utf8))
    exit(1)
}

signal(SIGTERM) { _ in exit(0) }
dispatchMain()
