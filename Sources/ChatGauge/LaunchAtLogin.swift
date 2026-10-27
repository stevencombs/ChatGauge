import Foundation
import ServiceManagement

/// Wraps SMAppService.mainApp. Only changed from the Settings switch; ChatGauge never adds itself on its own.
@MainActor
final class LaunchAtLogin: ObservableObject {
    @Published private(set) var isEnabled = SMAppService.mainApp.status == .enabled
    @Published private(set) var lastError: String?

    func refresh() { isEnabled = SMAppService.mainApp.status == .enabled }

    func set(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            lastError = nil
        } catch {
            lastError = SMAppService.mainApp.status == .requiresApproval
                ? "Approve ChatGauge in System Settings › General › Login Items."
                : "Couldn't change the login item."
        }
        refresh()
    }
}
