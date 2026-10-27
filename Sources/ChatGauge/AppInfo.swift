import AppKit

enum AppInfo {
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }
    static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
    }

    /// Placeholder until the GitHub repo exists.
    static let repo = "stevencombs/ChatGauge"
    static let repoURL = URL(string: "https://github.com/stevencombs/ChatGauge")!
    static let releasesURL = URL(string: "https://github.com/stevencombs/ChatGauge/releases")!
    static let clipGaugeURL = URL(string: "https://github.com/stevencombs/ClipGauge")!
    static let grokGaugeURL = URL(string: "https://github.com/stevencombs/GrokGauge")!
    static let youTubeMain = (handle: "@retroCombs", url: URL(string: "https://www.youtube.com/@retroCombs")!)
    static let youTubeTech = (handle: "@retroCombs-tech", url: URL(string: "https://www.youtube.com/@retroCombs-tech")!)
    static let contactEmail = "retroCombs@icloud.com"
    static let contactURL = URL(string: "mailto:retroCombs@icloud.com")!
    /// Tips (PayPal.Me). Opens in the browser; ChatGauge sends nothing.
    static let tipURL = URL(string: "https://paypal.me/stevencombs")!

    /// The retroCombs logo bundled in Contents/Resources (nil when running outside the .app).
    static var makerLogo: NSImage? {
        Bundle.main.url(forResource: "retrocombs-logo", withExtension: "png").flatMap { NSImage(contentsOf: $0) }
    }
}
