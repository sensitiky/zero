import Foundation
import Testing

@testable import ZeroCore

@Suite("LineAccumulator")
struct LineAccumulatorTests {
    private func text(_ records: [Data]) -> [String] {
        records.map { String(decoding: $0, as: UTF8.self) }
    }

    @Test("splits complete records on newlines")
    func splitsCompleteRecords() throws {
        var accumulator = LineAccumulator()
        let records = try accumulator.append(Data("{\"a\":1}\n{\"b\":2}\n".utf8))
        #expect(text(records) == [#"{"a":1}"#, #"{"b":2}"#])
        #expect(accumulator.flush() == nil)
    }

    @Test("reassembles a record split across chunks")
    func reassemblesAcrossChunks() throws {
        var accumulator = LineAccumulator()
        #expect(try accumulator.append(Data(#"{"partial":"#.utf8)).isEmpty)
        #expect(try accumulator.append(Data("true}".utf8)).isEmpty)
        let records = try accumulator.append(Data("\n".utf8))
        #expect(text(records) == [#"{"partial":true}"#])
    }

    @Test("reassembles a record split byte by byte")
    func reassemblesByteByByte() throws {
        var accumulator = LineAccumulator()
        var collected: [Data] = []
        for byte in Data("{\"x\":1}\n".utf8) {
            collected += try accumulator.append([byte])
        }
        #expect(text(collected) == [#"{"x":1}"#])
    }

    @Test("drops empty records")
    func dropsEmptyRecords() throws {
        var accumulator = LineAccumulator()
        let records = try accumulator.append(Data("\n\n{\"a\":1}\n\n".utf8))
        #expect(text(records) == [#"{"a":1}"#])
    }

    @Test("tolerates CRLF line endings")
    func toleratesCRLF() throws {
        var accumulator = LineAccumulator()
        let records = try accumulator.append(Data("{\"a\":1}\r\n".utf8))
        #expect(text(records) == [#"{"a":1}"#])
    }

    @Test("surfaces a trailing record at EOF without a newline")
    func surfacesTrailingRecord() throws {
        var accumulator = LineAccumulator()
        #expect(try accumulator.append(Data(#"{"trailing":true}"#.utf8)).isEmpty)
        let trailing = accumulator.flush()
        #expect(trailing.map { String(decoding: $0, as: UTF8.self) } == #"{"trailing":true}"#)
        #expect(accumulator.flush() == nil)
    }

    @Test("throws on a record past the size limit and recovers after it")
    func throwsOnOversizeRecord() throws {
        var accumulator = LineAccumulator(maxLineBytes: 8)
        #expect(throws: LineAccumulator.OversizeLine.self) {
            _ = try accumulator.append(Data(String(repeating: "x", count: 32).utf8))
        }
        let records = try accumulator.append(Data("{\"ok\":1}\n".utf8))
        #expect(text(records) == [#"{"ok":1}"#])
    }

    @Test("carries no state between records")
    func carriesNoStateBetweenRecords() throws {
        var accumulator = LineAccumulator()
        _ = try accumulator.append(Data("first\n".utf8))
        let records = try accumulator.append(Data("second\n".utf8))
        #expect(text(records) == ["second"])
    }
}
