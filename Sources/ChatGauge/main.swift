import AppKit
import ChatGaugeCore

let args = CommandLine.arguments.dropFirst()
if args.contains("--version") || args.contains("-v") {
    print("ChatGauge \(AppInfo.version) (\(AppInfo.build))")
    exit(0)
}
if args.contains("--help") || args.contains("-h") {
    print("""
    ChatGauge \(AppInfo.version): a local chat window for your menu bar, powered by Ollama.

    Usage: open ChatGauge.app
      --version   Print the version and exit
      --help      Show this help
    """)
    exit(0)
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    withExtendedLifetime(delegate) { app.run() }
}
