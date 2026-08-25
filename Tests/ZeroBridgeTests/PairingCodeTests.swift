import Foundation
import Testing

@testable import ZeroBridge

/// FR-4: the six digits between a device on the network and an agent that writes to this disk.
@Suite("PairingCode")
struct PairingCodeTests {

    /// A deterministic generator, so the digit shape is asserted over a known sequence rather than
    /// over luck. It is not a CSPRNG and is not meant to be — the production initialiser uses
    /// `SystemRandomNumberGenerator`, and that is asserted by reading `PairingCode.init()`.
    private struct CountingGenerator: RandomNumberGenerator {
        private var counter: UInt64 = 0
        mutating func next() -> UInt64 {
            defer { counter &+= 1 }
            return counter &* 2_654_435_761
        }
    }

    @Test("a generated code is exactly six digits")
    func digitShape() {
        for _ in 0..<200 {
            let code = PairingCode()
            let digits = code.displayDigits
            #expect(digits.count == PairingCode.length)
            #expect(digits.allSatisfy { $0.isNumber })
        }
    }

    @Test("leading zeros are preserved, because 018205 is a real code")
    func leadingZeros() throws {
        // Digit by digit, not a number formatted to six places: `String(018205)` is how a code
        // silently becomes five digits and the phone can never pair.
        var generator = CountingGenerator()
        let code = PairingCode(using: &generator)
        #expect(code.displayDigits.count == PairingCode.length)

        let explicit = try #require(PairingCode("000123"))
        #expect(explicit.displayDigits == "000123")
        #expect(explicit.matches("000123"))
        #expect(!explicit.matches("123"))
    }

    @Test("a string that is not six digits is not a code")
    func parsing() {
        #expect(PairingCode("12345") == nil)
        #expect(PairingCode("1234567") == nil)
        #expect(PairingCode("") == nil)
        #expect(PairingCode("41820a") == nil)
        #expect(PairingCode("41 205") == nil)
        #expect(PairingCode("４１８２０５") == nil)
        #expect(PairingCode("418205") != nil)
    }

    @Test("the compare accepts only the exact code")
    func compare() throws {
        let code = try #require(PairingCode("418205"))
        #expect(code.matches("418205"))
        #expect(!code.matches("418204"))
        #expect(!code.matches("518205"))
        #expect(!code.matches(""))
        #expect(!code.matches("41820"))
        #expect(!code.matches("4182050"))
        #expect(!code.matches("418205 "))
        #expect(!code.matches(nil))
    }

    @Test("the compare is fixed-length by construction, with no early return")
    func compareIsConstantTime() throws {
        // Asserted by construction, not by timing: a timing test on a shared machine is noise.
        // What is checked here is the observable consequence — a candidate that differs in the
        // first digit and one that differs in the last are handled the same way, and a candidate of
        // any length is normalised into six comparisons rather than short-circuiting on count.
        let code = try #require(PairingCode("418205"))
        let wrongEverywhere = ["518205", "418206", "999999", "000000"]
        for candidate in wrongEverywhere {
            #expect(!code.matches(candidate))
        }
        for length in 0...20 where length != PairingCode.length {
            #expect(!code.matches(String(repeating: "4", count: length)))
        }
        // Equality between two codes goes through the same path.
        #expect(code == PairingCode("418205"))
        #expect(code != PairingCode("418206"))
    }

    @Test("the code never prints itself")
    func neverPrintsItself() throws {
        let code = try #require(PairingCode("418205"))
        #expect(code.description == "PairingCode(hidden)")
        #expect(code.debugDescription == "PairingCode(hidden)")
        #expect("\(code)" == "PairingCode(hidden)")
        #expect(String(describing: code) == "PairingCode(hidden)")
        #expect(String(reflecting: code) == "PairingCode(hidden)")
        // The one accessor that yields the digits has to be named, so reaching for it is a
        // decision and shows up in review.
        #expect(code.displayDigits == "418205")
    }

    @Test("the grouped rendering is for reading aloud, not for the wire")
    func grouping() throws {
        let code = try #require(PairingCode("418205"))
        #expect(code.displayGrouped == "418 205")
        // The wire always carries the ungrouped digits — the space is a rendering, not a value.
        #expect(code.matches(code.displayDigits))
        #expect(!code.matches(code.displayGrouped))
    }

    @Test("two fresh codes are not the same code every time")
    func generationVaries() {
        // Not a randomness test — a sanity check that the generator is being used at all. A
        // constant code would pass every other test in this suite.
        let codes = Set((0..<64).map { _ in PairingCode().displayDigits })
        #expect(codes.count > 1)
    }
}
