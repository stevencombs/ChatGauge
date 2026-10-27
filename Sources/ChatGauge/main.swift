import AppKit
import ChatGaugeCore

// Placeholder entry point while Core lands (Milestone 2 replaces it with the menu bar app).
if CommandLine.arguments.contains("--version") {
    print("ChatGauge \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")")
    exit(0)
}
print("ChatGauge core ready. Tier: \(TierDetector.detect().rawValue)")
