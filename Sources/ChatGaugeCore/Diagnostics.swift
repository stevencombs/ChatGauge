import Foundation

/// The plain-text report on Settings › Diagnostics. Paths are shortened to `~` and nothing secret is included.
public struct DiagnosticsReport: Equatable, Sendable {
    public var lines: [(String, String)]

    public init(lines: [(String, String)]) { self.lines = lines }

    public static func == (a: Self, b: Self) -> Bool { a.text == b.text }

    /// Replaces the home folder with `~` so a pasted report doesn't carry the account name.
    public static func scrub(_ s: String, home: String = NSHomeDirectory()) -> String {
        guard !home.isEmpty, home != "/" else { return s }
        return s.replacingOccurrences(of: home, with: "~")
    }

    public func text(home: String = NSHomeDirectory()) -> String {
        let width = min(24, lines.map(\.0.count).max() ?? 0)
        return lines.map { k, v in
            let pad = String(repeating: " ", count: max(0, width - k.count))
            return "\(k):\(pad) \(Self.scrub(v, home: home))"
        }.joined(separator: "\n")
    }

    public var text: String { text() }
}
