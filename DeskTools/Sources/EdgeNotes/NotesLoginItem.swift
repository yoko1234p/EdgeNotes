import Combine
import DeskCore
import Foundation
import ServiceManagement

@MainActor final class NotesLoginItem: ObservableObject {
    @Published private(set) var status: SMAppService.Status
    @Published private(set) var error = ""
    private let readStatus: () -> SMAppService.Status
    private let register: () throws -> Void
    private let unregister: () throws -> Void
    private let openSettings: () -> Void

    init(
        readStatus: @escaping () -> SMAppService.Status = { SMAppService.mainApp.status },
        register: @escaping () throws -> Void = { try SMAppService.mainApp.register() },
        unregister: @escaping () throws -> Void = { try SMAppService.mainApp.unregister() },
        openSettings: @escaping () -> Void = { SMAppService.openSystemSettingsLoginItems() }
    ) {
        self.readStatus = readStatus
        self.register = register
        self.unregister = unregister
        self.openSettings = openSettings
        status = readStatus()
    }

    var isRegistered: Bool { status == .enabled || status == .requiresApproval }

    var summary: String {
        switch status {
        case .enabled: return L10n.text("已開啟；登入後側邊短條及選單列會自動待命。")
        case .requiresApproval: return L10n.text("已加入登入項目；請在系統設定允許 EdgeNotes。")
        case .notRegistered: return L10n.text("未開啟開機登入後自動啟動。")
        case .notFound: return L10n.text("找不到 EdgeNotes 登入項目；請由已安裝的 App 開啟設定。")
        @unknown default: return L10n.text("未能確認登入項目狀態。")
        }
    }

    func refresh() { status = readStatus() }

    func setEnabled(_ enabled: Bool) {
        refresh()
        error = ""
        guard enabled != isRegistered else { return }
        do {
            if enabled { try register() } else { try unregister() }
        } catch {
            self.error = L10n.text("未能更改開機啟動：%1$@", String(describing: error.localizedDescription))
        }
        refresh()
    }

    func showSettings() { openSettings() }
}
