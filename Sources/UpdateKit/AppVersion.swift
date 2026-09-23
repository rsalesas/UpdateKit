import Foundation

/// A dotted numeric version ("0.2.10"), compared component-wise.
///
/// String comparison is wrong here — "0.2.10" sorts *before* "0.2.9" — and this is
/// the one piece of the update check that silently does nothing when it's wrong, so
/// it's a type of its own with tests rather than an inline `<`.
public struct AppVersion: Comparable, CustomStringConvertible, Sendable {
    public let components: [Int]

    /// Nil for anything that isn't dot-separated numbers, so a malformed manifest
    /// can't be read as "newer".
    public init?(_ string: String) {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var parsed: [Int] = []
        for part in trimmed.split(separator: ".", omittingEmptySubsequences: false) {
            guard let n = Int(part), n >= 0 else { return nil }
            parsed.append(n)
        }
        guard !parsed.isEmpty else { return nil }
        components = parsed
    }

    /// Missing trailing components read as zero, so "0.2" == "0.2.0".
    public static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        for i in 0..<count {
            let l = i < lhs.components.count ? lhs.components[i] : 0
            let r = i < rhs.components.count ? rhs.components[i] : 0
            if l != r { return l < r }
        }
        return false
    }

    public static func == (lhs: AppVersion, rhs: AppVersion) -> Bool {
        !(lhs < rhs) && !(rhs < lhs)
    }

    public var description: String { components.map(String.init).joined(separator: ".") }
}
