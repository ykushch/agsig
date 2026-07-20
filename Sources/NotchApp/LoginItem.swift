import Foundation
import ServiceManagement

enum LoginItem {
    static func setEnabled(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("Couldn't update launch-at-login: %@", String(describing: error))
        }
    }

    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }
}
