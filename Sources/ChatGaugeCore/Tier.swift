import Foundation

/// The RAM tier picks the default model, keep-loaded and the whisper model.
/// Thresholds follow ClipGauge's `ram-tiers.json`: Air under 32 GB, Pro at 48 GB or more.
/// A Mac in between uses the Air rules.
public enum RAMTier: String, Codable, Sendable, CaseIterable {
    case air, pro

    public var title: String { self == .air ? "Air (under 48 GB)" : "Pro (48 GB or more)" }
}

public struct TierRules: Equatable, Sendable {
    public var airBelowGB: Double = 32
    public var proAtLeastGB: Double = 48
    public var preferred: [RAMTier: String] = [.air: "qwen2.5vl:7b", .pro: "qwen2.5vl:7b"]
    public var whisper: [RAMTier: [String]] = [
        .air: ["base.en", "small.en", "tiny.en"],
        .pro: ["large-v3-turbo", "medium.en", "small.en"],
    ]

    public init() {}

    public static let standard = TierRules()

    /// Reads ClipGauge-style `ram-tiers.json` (optional; missing keys keep the defaults).
    public static func parse(_ data: Data) -> TierRules {
        var r = TierRules()
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return r }
        if let det = o["detection"] as? [String: Any] {
            if let a = (det["air_if_gb_lt"] as? NSNumber)?.doubleValue { r.airBelowGB = a }
            if let p = (det["pro_if_gb_gte"] as? NSNumber)?.doubleValue { r.proAtLeastGB = p }
        }
        if let tiers = o["tiers"] as? [String: Any] {
            for t in RAMTier.allCases {
                guard let d = tiers[t.rawValue] as? [String: Any] else { continue }
                if let p = d["prefer"] as? String, !p.isEmpty { r.preferred[t] = p }
                if let w = d["whisper_model"] as? String, !w.isEmpty {
                    r.whisper[t] = [w] + ((d["whisper_alternates"] as? [String]) ?? [])
                }
            }
        }
        return r
    }

    public func tier(memBytes: UInt64) -> RAMTier {
        let gb = Double(memBytes) / 1_073_741_824
        return gb >= proAtLeastGB ? .pro : .air
    }
}

public enum TierDetector {
    /// Physical RAM from `hw.memsize`.
    public static func memBytes() -> UInt64 {
        #if canImport(Darwin)
        var size: UInt64 = 0
        var len = MemoryLayout<UInt64>.size
        if sysctlbyname("hw.memsize", &size, &len, nil, 0) == 0 { return size }
        #endif
        return ProcessInfo.processInfo.physicalMemory
    }

    public static func detect(rules: TierRules = .standard, override: String? = nil, memBytes: UInt64 = memBytes()) -> RAMTier {
        if let o = override, let t = RAMTier(rawValue: o.lowercased()) { return t }
        return rules.tier(memBytes: memBytes)
    }
}
