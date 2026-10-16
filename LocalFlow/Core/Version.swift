import Foundation

struct Version: Comparable, CustomStringConvertible, Equatable {
    let parts: [Int]

    init?(_ string: String) {
        let digits = string.hasPrefix("v") ? String(string.dropFirst()) : string
        let parts = digits.split(separator: ".").map { Int($0) }
        guard !parts.isEmpty, !parts.contains(nil) else { return nil }
        self.parts = parts.compactMap { $0 }
    }

    static func < (lhs: Version, rhs: Version) -> Bool {
        let count = max(lhs.parts.count, rhs.parts.count)
        let l = lhs.parts + Array(repeating: 0, count: count - lhs.parts.count)
        let r = rhs.parts + Array(repeating: 0, count: count - rhs.parts.count)
        return l.lexicographicallyPrecedes(r)
    }

    var description: String { parts.map(String.init).joined(separator: ".") }
}
