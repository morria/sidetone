import Foundation

/// An amateur-radio callsign, always stored uppercase.
///
/// Validation is intentionally permissive. Amateur callsigns around the world
/// do not fit a single regex (Swaziland's 3DA0RU, Vatican's HV, special-event
/// calls, etc.) and the app's job is to talk to whoever shows up on the band,
/// not to reject unusual ones. We enforce only the properties ardopcf itself
/// requires: at least one letter AND one digit, length 3–12 for the base call,
/// ASCII only, with an optional portable suffix (`/P`, `/M`, `/MM`, `/AM`,
/// `/R`, or any 1–3 alnum chars).
public struct Callsign: Hashable, Sendable, Codable, CustomStringConvertible {
    public let value: String

    public init?(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard Self.isValid(trimmed) else { return nil }
        self.value = trimmed
    }

    public var description: String { value }

    public static func isValid(_ candidate: String) -> Bool {
        guard !candidate.isEmpty, candidate.count <= 16 else { return false }
        let parts = candidate.split(separator: "/", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return false }
        guard let base = parts.first, isValidBase(String(base)) else { return false }
        for suffix in parts.dropFirst() {
            guard isValidSuffix(String(suffix)) else { return false }
        }
        return true
    }

    private static func isValidBase(_ base: String) -> Bool {
        guard (3...12).contains(base.count) else { return false }
        var hasLetter = false
        var hasDigit = false
        for ch in base {
            if ch.isLetter, ch.isASCII { hasLetter = true }
            else if ch.isNumber, ch.isASCII { hasDigit = true }
            else { return false }
        }
        return hasLetter && hasDigit
    }

    private static func isValidSuffix(_ suffix: String) -> Bool {
        guard (1...3).contains(suffix.count) else { return false }
        return suffix.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }
}
