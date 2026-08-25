import Foundation

/// The six digits that stand between a device on the network and an agent that writes to this disk
/// (FR-4).
///
/// Three things about it are load-bearing:
///
/// - **It is generated with a CSPRNG.** `SystemRandomNumberGenerator` is the platform's, seeded by
///   the kernel. A code from a seeded PRNG is a code that can be predicted from the clock.
/// - **It is compared in constant time.** The compare is a fixed-length XOR-accumulate over the
///   whole code, with no early return, so how long it takes says nothing about how many digits were
///   right.
/// - **It never prints itself.** `description` and `debugDescription` return a placeholder, so the
///   code cannot reach a log by way of a `print`, an interpolation, an error message or a crash
///   report. The one accessor that yields the digits is named so that using it is a decision:
///   `displayDigits`, which the window calls and nothing else does.
public struct PairingCode: Sendable, CustomStringConvertible, CustomDebugStringConvertible {

    /// Six, everywhere. A length that lives in one place cannot drift between generate and compare.
    public static let length = 6

    private let digits: [UInt8]

    /// A fresh code. `SystemRandomNumberGenerator` is the CSPRNG FR-4 asks for.
    public init() {
        var generator = SystemRandomNumberGenerator()
        self.init(using: &generator)
    }

    /// Injectable generator, so the tests can assert the digit shape over a deterministic sequence
    /// instead of over luck.
    public init(using generator: inout some RandomNumberGenerator) {
        // Digit by digit rather than one number formatted to six places: a leading zero is a real
        // code (`018205`), and `String(042005)` is how it silently becomes five digits.
        digits = (0..<Self.length).map { _ in UInt8.random(in: 0...9, using: &generator) }
    }

    /// A code from a known string, for tests and for a caller restoring one. Nil unless it is
    /// exactly six digits — leading zeros preserved.
    public init?(_ string: String) {
        let bytes = Array(string.utf8)
        guard bytes.count == Self.length else { return nil }
        var parsed: [UInt8] = []
        parsed.reserveCapacity(Self.length)
        for byte in bytes {
            guard byte >= 0x30, byte <= 0x39 else { return nil }
            parsed.append(byte - 0x30)
        }
        digits = parsed
    }

    /// The digits, for the one place that shows them: the Zero window (FR-27).
    ///
    /// Deliberately not `description`. Anything that reaches this has to name it.
    public var displayDigits: String {
        String(digits.map { Character(UnicodeScalar(0x30 + $0)) })
    }

    /// The same six digits, grouped for reading out loud across a desk. The wire always carries
    /// `displayDigits` — the space is a rendering, not a value.
    public var displayGrouped: String {
        let raw = displayDigits
        let middle = raw.index(raw.startIndex, offsetBy: Self.length / 2)
        return "\(raw[raw.startIndex..<middle]) \(raw[middle...])"
    }

    /// Constant-time comparison against whatever the client sent.
    ///
    /// Fixed-length by construction: the candidate is normalised into a six-byte array first, so the
    /// loop always runs six times whatever arrives — a compare that returns early on the first wrong
    /// digit leaks the code one digit at a time to anyone who can measure a round trip. The length
    /// check is folded into the accumulator rather than short-circuiting it.
    public func matches(_ candidate: String?) -> Bool {
        guard let candidate else { return false }
        let bytes = Array(candidate.utf8)
        var difference: UInt8 = bytes.count == Self.length ? 0 : 1
        for index in 0..<Self.length {
            let sent = index < bytes.count ? bytes[index] : 0
            difference |= sent ^ (0x30 + digits[index])
        }
        return difference == 0
    }

    /// Never the code. This is the whole reason the type exists rather than a `String`.
    public var description: String { "PairingCode(hidden)" }
    public var debugDescription: String { "PairingCode(hidden)" }
}

extension PairingCode: Equatable {
    /// Constant-time, so even a test or a future caller comparing two codes cannot introduce a
    /// timing side channel by accident.
    public static func == (lhs: PairingCode, rhs: PairingCode) -> Bool {
        lhs.matches(rhs.displayDigits)
    }
}
