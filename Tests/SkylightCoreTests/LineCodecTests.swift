import XCTest
import SkylightCore

final class LineCodecTests: XCTestCase {
    func testSplitsCompleteLines() throws {
        let codec = LineCodec()
        let lines = try codec.append(Data("{\"a\":1}\n{\"b\":2}\n".utf8))
        XCTAssertEqual(lines.map { String(data: $0, encoding: .utf8)! }, ["{\"a\":1}", "{\"b\":2}"])
    }

    func testBuffersPartialLineAcrossAppends() throws {
        let codec = LineCodec()
        XCTAssertEqual(try codec.append(Data("{\"a\"".utf8)), [])
        let lines = try codec.append(Data(":1}\n".utf8))
        XCTAssertEqual(lines.map { String(data: $0, encoding: .utf8)! }, ["{\"a\":1}"])
    }

    func testRejectsOversizedCompleteLine() {
        let codec = LineCodec()
        let big = Data(repeating: 0x61, count: LineCodec.maxLineBytes + 1) + Data("\n".utf8)
        XCTAssertThrowsError(try codec.append(big)) { error in
            XCTAssertEqual(error as? LineCodecError, .lineTooLong(LineCodec.maxLineBytes + 1))
        }
    }

    func testRejectsOversizedUnterminatedBuffer() {
        let codec = LineCodec()
        let big = Data(repeating: 0x61, count: LineCodec.maxLineBytes + 1)
        XCTAssertThrowsError(try codec.append(big)) { error in
            XCTAssertEqual(error as? LineCodecError, .lineTooLong(LineCodec.maxLineBytes + 1))
        }
    }

    func testAcceptsExactlyMaxLineBytes() throws {
        let codec = LineCodec()
        let exactMax = Data(repeating: 0x61, count: LineCodec.maxLineBytes) + Data("\n".utf8)
        let lines = try codec.append(exactMax)
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines[0].count, LineCodec.maxLineBytes)
    }
}
