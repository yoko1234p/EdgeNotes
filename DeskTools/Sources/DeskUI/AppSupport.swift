import AppKit
import Carbon
import DeskCore
import LocalWorkflowKit
import SwiftUI

@MainActor public enum AppSupport {
    public static func window<V: View>(_ title: String, size: NSSize, view: V) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = title
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: min(size.width, 620), height: min(size.height, 460))
        window.contentView = NSHostingView(rootView: view)
        window.center()
        return window
    }

    public static func show(_ window: NSWindow) {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    public static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    public static func export(_ text: String, name: String = L10n.text("文字.txt")) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        if panel.runModal() == .OK, let url = panel.url {
            do { try BoundedFile.write(Data(text.utf8), to: url) } catch { NSAlert(error: error).runModal() }
        }
    }

    public static func sendToNotes(_ text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        do {
            guard text.utf8.count <= 1_000_000 else { throw DeskError.invalid(L10n.text("交接文字最多 1 MB。")) }
            let directory = try BoundedFile.privateDirectory("DeskTools Handoff")
            let url = directory.appendingPathComponent(UUID().uuidString + ".edgetext")
            // Remove only our own old payloads, never arbitrary temporary files.
            for old in try FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.contentModificationDateKey])
            where old.pathExtension == "edgetext" {
                if let date = try old.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                    date < Date().addingTimeInterval(-86400)
                {
                    try? FileManager.default.removeItem(at: old)
                }
            }
            try BoundedFile.write(Data(text.utf8), to: url)
            guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "local.pakwingho.edgenotes")
            else {
                try? FileManager.default.removeItem(at: url)
                throw DeskError.invalid(L10n.text("找不到 EdgeNotes，請先安裝或使用匯出文字。"))
            }
            NSWorkspace.shared.open([url], withApplicationAt: app, configuration: .init()) { _, error in
                if let error { Task { @MainActor in NSAlert(error: error).runModal() } }
            }
        } catch { NSAlert(error: error).runModal() }
    }
    public static func sendDraft(_ draft: WorkflowDraft) {
        do {
            let bundleID = draft.kind == .note ? "local.pakwingho.edgenotes" : "local.pakwingho.notchhub"
            let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            guard let app else {
                throw WorkflowError.invalid(
                    L10n.text("找不到接收 App，請先安裝 ") + (draft.kind == .note ? "EdgeNotes。" : "NotchHub。"))
            }
            let url = try WorkflowFiles.writeDraft(draft)
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = draft.kind == .vocabulary || draft.targetNoteID == nil
            NSWorkspace.shared.open([url], withApplicationAt: app, configuration: configuration) { _, error in
                if let error { Task { @MainActor in NSAlert(error: error).runModal() } }
            }
        } catch { NSAlert(error: error).runModal() }
    }

    public static func standardMenu(_ name: String) {
        let menu = NSMenu()
        let application = NSMenuItem()
        menu.addItem(application)
        let actions = NSMenu()
        actions.addItem(
            withTitle: L10n.text("關於 %1$@", String(describing: name)),
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: "")
        actions.addItem(.separator())
        actions.addItem(
            withTitle: L10n.text("結束 %1$@", String(describing: name)), action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q")
        application.submenu = actions
        let edit = NSMenuItem()
        menu.addItem(edit)
        let editing = NSMenu(title: L10n.text("編輯"))
        for (label, selector, key) in [
            (L10n.text("復原"), "undo:", "z"), (L10n.text("剪下"), "cut:", "x"),
            (L10n.text("複製"), "copy:", "c"), (L10n.text("貼上"), "paste:", "v"), (L10n.text("全選"), "selectAll:", "a"),
        ] {
            editing.addItem(withTitle: label, action: Selector(selector), keyEquivalent: key)
        }
        edit.submenu = editing
        NSApp.mainMenu = menu
    }
}

@MainActor public final class GlobalHotKey {
    private static var nextID: UInt32 = 0
    private let identifier: UInt32
    private var reference: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let action: () -> Void
    public init(action: @escaping () -> Void) {
        Self.nextID += 1
        identifier = Self.nextID
        self.action = action
    }

    @discardableResult public func register(key: UInt32, modifiers: UInt32) -> Bool {
        if let reference {
            UnregisterEventHotKey(reference)
            self.reference = nil
        }
        if handler == nil {
            var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            let pointer = Unmanaged.passUnretained(self).toOpaque()
            InstallEventHandler(
                GetApplicationEventTarget(),
                { _, event, pointer in
                    guard let pointer, let event else { return OSStatus(eventNotHandledErr) }
                    let object = Unmanaged<GlobalHotKey>.fromOpaque(pointer).takeUnretainedValue()
                    var hotkey = EventHotKeyID()
                    guard
                        GetEventParameter(
                            event, EventParamName(kEventParamDirectObject),
                            EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &hotkey)
                            == noErr,
                        hotkey.signature == 0x4453_4B54, hotkey.id == object.identifier
                    else { return OSStatus(eventNotHandledErr) }
                    Task { @MainActor in object.action() }
                    return noErr
                }, 1, &event, pointer, &handler)
        }
        let status = RegisterEventHotKey(
            key, modifiers, EventHotKeyID(signature: 0x4453_4B54, id: identifier),
            GetApplicationEventTarget(), 0, &reference)
        return status == noErr
    }

    deinit {
        if let reference { UnregisterEventHotKey(reference) }
        if let handler { RemoveEventHandler(handler) }
    }
}

public struct DeskHeader: View {
    let title: String
    let subtitle: String
    let symbol: String
    let color: Color
    public init(_ title: String, subtitle: String, symbol: String, color: Color) {
        self.title = title
        self.subtitle = subtitle
        self.symbol = symbol
        self.color = color
    }
    public var body: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol).font(.system(size: 25, weight: .medium))
                .frame(width: 54, height: 54).background(color.opacity(0.15), in: RoundedRectangle(cornerRadius: 15))
                .foregroundStyle(color)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.system(size: 23, weight: .semibold))
                Text(subtitle).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }
}
