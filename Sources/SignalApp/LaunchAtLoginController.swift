import Foundation
import Combine
import ServiceManagement

@MainActor
final class LaunchAtLoginController: ObservableObject {
    @Published private(set) var status: SMAppService.Status

    init() {
        status = Self.currentStatus
    }

    var isEnabled: Bool { status == .enabled }

    var needsApproval: Bool { status == .requiresApproval }

    func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
        status = Self.currentStatus
    }

    func refresh() {
        status = Self.currentStatus
    }

    private static var currentStatus: SMAppService.Status {
        SMAppService.mainApp.status
    }
}
