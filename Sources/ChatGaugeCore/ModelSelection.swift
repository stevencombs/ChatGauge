import Foundation

public enum ModelSelection {
    /// The model to use when nothing is low on memory: the user's pick if installed, else the tier default,
    /// else the same model under another tag, else any vision model, else any model.
    public static func preferred(choice: ModelChoice, tier: RAMTier, rules: TierRules = .standard,
                                 installed: [ModelInfo]) -> String? {
        let names = installed.map(\.name)
        if let n = choice.name, names.contains(n) { return n }
        let want = rules.preferred[tier] ?? "qwen2.5vl:7b"
        if names.contains(want) { return want }
        let base = String(want.split(separator: ":").first ?? "")
        if let same = installed.filter({ $0.base == base }).sorted(by: { ($0.billions ?? 0) < ($1.billions ?? 0) }).first { return same.name }
        if let v = installed.first(where: \.supportsVision) { return v.name }
        return names.first
    }

    /// Fallback steps (smaller first) for a chosen model. Only installed models; never downloads.
    /// qwen2.5vl: 32b → 7b → 3b. Other families: the next smaller installed model in the family, then qwen2.5vl:7b.
    public static func fallbackChain(for model: String, installed: [ModelInfo]) -> [String] {
        guard let current = installed.first(where: { $0.name == model }) else { return [] }
        let size = current.billions ?? .infinity
        var chain = installed
            .filter { $0.base == current.base && $0.name != model && ($0.billions ?? .infinity) < size }
            .sorted { ($0.billions ?? 0) > ($1.billions ?? 0) }
            .map(\.name)
        if current.base != "qwen2.5vl" {
            for n in ["qwen2.5vl:7b", "qwen2.5vl:3b"] where installed.contains(where: { $0.name == n }) && !chain.contains(n) {
                if let b = installed.first(where: { $0.name == n })?.billions, b < size { chain.append(n) }
            }
        }
        return chain
    }
}

/// Memory pressure as reported by macOS (DispatchSource memory pressure events).
public enum MemoryPressure: Int, Comparable, Sendable {
    case normal = 0, warning, critical
    public static func < (a: MemoryPressure, b: MemoryPressure) -> Bool { a.rawValue < b.rawValue }
}

/// Decides the model for the next request given memory, with a cooldown so it never flip-flops.
/// A request that is already streaming is never touched; this only runs before a new one.
public struct MemoryFallback: Equatable, Sendable {
    public var cooldown: TimeInterval = 180
    /// Extra free memory needed on top of the model's size (bytes).
    public var safetyMargin: Int64 = 2 * 1_073_741_824
    public private(set) var active: String? = nil
    public private(set) var lastSwitch: Date? = nil

    public init(cooldown: TimeInterval = 180) { self.cooldown = cooldown }

    public struct Decision: Equatable, Sendable {
        public var model: String
        /// Set while a smaller model is in use instead of `preferred`.
        public var note: String?
        /// Memory is low but there is nothing smaller installed: replies may be slow, stop preloading.
        public var slow: Bool
    }

    /// - Parameters:
    ///   - available: free + inactive bytes right now
    ///   - sizes: model name → bytes (from /api/ps size when loaded, else /api/tags size)
    ///   - loaded: names currently loaded (a loaded model needs no new memory)
    public mutating func decide(preferred: String, chain: [String], pressure: MemoryPressure, available: Int64,
                                sizes: [String: Int64], loaded: Set<String>, enabled: Bool, now: Date = Date()) -> Decision {
        guard enabled else {
            active = nil
            return Decision(model: preferred, note: nil, slow: false)
        }
        func fits(_ m: String) -> Bool {
            if loaded.contains(m) { return pressure < .critical }
            guard let s = sizes[m], s > 0 else { return pressure == .normal }
            return pressure < .critical && available >= s + safetyMargin
        }
        let inCooldown = lastSwitch.map { now.timeIntervalSince($0) < cooldown } ?? false
        let low = pressure >= .warning || !fits(preferred)

        if let cur = active {
            // Switch back only once memory is normal, the preferred model fits, and the cooldown has passed.
            if !low && pressure == .normal && !inCooldown {
                active = nil
                lastSwitch = now
                return Decision(model: preferred, note: nil, slow: false)
            }
            // Step down further if even the fallback is too big and the cooldown allows.
            if !fits(cur) && !inCooldown, let i = chain.firstIndex(of: cur), i + 1 < chain.count {
                active = chain[i + 1]
                lastSwitch = now
            }
            return Decision(model: active!, note: Self.note(active!, instead: preferred), slow: false)
        }
        guard low else { return Decision(model: preferred, note: nil, slow: false) }
        guard !chain.isEmpty else { return Decision(model: preferred, note: "Memory is low, so replies may be slow.", slow: true) }
        if inCooldown { return Decision(model: preferred, note: nil, slow: false) }
        let pick = chain.first(where: fits) ?? chain.last!
        active = pick
        lastSwitch = now
        return Decision(model: pick, note: Self.note(pick, instead: preferred), slow: false)
    }

    public static func note(_ model: String, instead preferred: String) -> String {
        "Memory is low, so this reply uses \(model) instead of \(preferred). ChatGauge switches back when memory frees up."
    }
}

/// The models ChatGauge itself loaded. On quit (or a switch) only these are unloaded, never everything in /api/ps.
public struct LoadLedger: Equatable, Sendable {
    public private(set) var mine: Set<String> = []
    public init() {}

    /// Record a model ChatGauge loaded, unless it was already loaded by someone else.
    public mutating func recordLoad(_ model: String, wasAlreadyLoaded: Bool) {
        if !wasAlreadyLoaded { mine.insert(model) }
    }

    public mutating func recordUnload(_ model: String) { mine.remove(model) }

    /// What to unload now: ours that are still loaded.
    public func toUnload(loadedNow: [String]) -> [String] {
        loadedNow.filter { mine.contains($0) }.sorted()
    }
}

/// DaVinci Resolve detection: warn once per Resolve session, never block.
public struct ResolveWatch: Equatable, Sendable {
    public static let bundlePrefixes = ["com.blackmagic-design.DaVinciResolve"]
    public private(set) var running = false
    public private(set) var warnedThisSession = false

    public init() {}

    public static func isResolve(bundleID: String?) -> Bool {
        guard let b = bundleID else { return false }
        return bundlePrefixes.contains { b.hasPrefix($0) }
    }

    /// Feed the current running apps; returns true when the one-time note should show now.
    public mutating func update(runningBundleIDs: [String?], enabled: Bool) -> Bool {
        let now = runningBundleIDs.contains { Self.isResolve(bundleID: $0) }
        defer { running = now }
        if !now {
            warnedThisSession = false   // the next Resolve launch is a new session
            return false
        }
        guard enabled, !warnedThisSession else { return false }
        warnedThisSession = true
        return true
    }

    public static let note = "DaVinci Resolve is open. Resolve and the model share memory, so replies may be slower, and ChatGauge will switch to a smaller model if memory runs low. Chat keeps working."
}
