import Foundation

public enum LineCodecError: Error, Equatable {
    case lineTooLong(Int)
}

/// Accumulates raw socket bytes and yields complete newline-terminated lines.
/// Lines longer than `maxLineBytes` (1 MiB) are a protocol violation.
public final class LineCodec {
    public static let maxLineBytes = 1_048_576
    private var buffer = Data()

    public init() {}

    public func append(_ data: Data) throws -> [Data] {
        buffer.append(data)
        var lines: [Data] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer.subdata(in: buffer.startIndex..<newline)
            buffer.removeSubrange(buffer.startIndex...newline)
            if line.count > Self.maxLineBytes {
                throw LineCodecError.lineTooLong(line.count)
            }
            lines.append(line)
        }
        if buffer.count > Self.maxLineBytes {
            throw LineCodecError.lineTooLong(buffer.count)
        }
        return lines
    }
}
