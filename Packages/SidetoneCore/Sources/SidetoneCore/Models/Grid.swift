import Foundation

/// A Maidenhead grid locator of length 2, 4, 6, or 8.
///
/// Canonical format alternates between field letters (A–R), square digits
/// (0–9), subsquare letters (A–X, case-insensitive on input), and extended
/// digits (0–9). We store the canonical "Aa0Bb1" casing used on QSO cards and
/// in ADIF: upper-upper digit-digit lower-lower digit-digit.
public struct Grid: Hashable, Sendable, Codable, CustomStringConvertible {
    public let value: String

    public init?(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let canonical = Self.canonicalize(trimmed) else { return nil }
        self.value = canonical
    }

    public var description: String { value }

    public var precisionChars: Int { value.count }

    private static func canonicalize(_ raw: String) -> String? {
        guard [2, 4, 6, 8].contains(raw.count) else { return nil }
        let upper = raw.uppercased()
        var out = ""
        for (i, ch) in upper.enumerated() {
            switch i {
            case 0, 1:
                guard ch.isASCII, ch.isLetter, ("A"..."R").contains(ch) else { return nil }
                out.append(ch)
            case 2, 3:
                guard ch.isASCII, ch.isNumber else { return nil }
                out.append(ch)
            case 4, 5:
                guard ch.isASCII, ch.isLetter, ("A"..."X").contains(ch) else { return nil }
                out.append(Character(ch.lowercased()))
            case 6, 7:
                guard ch.isASCII, ch.isNumber else { return nil }
                out.append(ch)
            default:
                return nil
            }
        }
        return out
    }
}
