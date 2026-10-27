import AppKit
import ChatGaugeCore
import SwiftUI

/// `@State` is a compiler macro in recent SDKs, and the Command Line Tools don't ship SwiftUI's
/// macro plugin. The underlying property-wrapper type through an alias behaves the same.
typealias ViewState<Value> = SwiftUI.State<Value>

/// Status colors: system colors, so they adapt to light/dark mode and Increase Contrast.
enum Palette {
    static func nsColor(_ level: EngineStatus.Level) -> NSColor {
        switch level {
        case .ok: return .systemGreen
        case .busy: return .systemOrange
        case .problem: return .systemRed
        case .neutral: return .secondaryLabelColor
        }
    }

    static func color(_ level: EngineStatus.Level) -> Color { Color(nsColor: nsColor(level)) }
}
