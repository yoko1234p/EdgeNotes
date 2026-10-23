import AppKit
import Carbon
import DeskCore
import DeskUI
import NotesCore
import QuartzCore
import SwiftUI

@MainActor final class NotesDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let model: NotesModel
    let loginItem = NotesLoginItem()
    override init() {
        if let index = CommandLine.arguments.firstIndex(of: "--data-directory"),
            CommandLine.arguments.indices.contains(index + 1), CommandLine.arguments[index + 1].hasPrefix("/")
        {
            model = NotesModel(directory: URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true))
        } else {
            model = NotesModel()
        }
        super.init()
    }
    var panel: NSPanel!
    var status: NSStatusItem!
    var hotkey: GlobalHotKey!
    var clipboardHotkey: GlobalHotKey!
    var bars: [NSPanel] = []
    var previousApp: NSRunningApplication?
    private var workflow = EdgePanelWorkflow()
    private var anchoredDisplay: UInt32?
    private var shownFrame: NSRect?
    private var fitsDisplayHeight = true
    private var heightBeforeResize: CGFloat?
    var keyboardMonitor: Any?
    var resignObserver: NSObjectProtocol?
    var mouseMonitor: Any?
    var localMouseMonitor: Any?
    private var mouseDownMonitor: Any?
    private var localMouseDownMonitor: Any?
    private var trackedMenus = 0
    var dwell: DispatchWorkItem?
    private var dwellDisplay: UInt32?
    private var dwellSide: EdgePanelSide?
    var observer: NSObjectProtocol?
    private var ready = false
    private var pendingShow = false
    private var waitingToTerminate = false
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        AppSupport.standardMenu("EdgeNotes")
        if let editing = NSApp.mainMenu?.items.compactMap(\.submenu).first(where: { $0.title == L10n.text("編輯") }) {
            let redo = NSMenuItem(title: L10n.text("重做"), action: Selector(("redo:")), keyEquivalent: "z")
            redo.keyEquivalentModifierMask = [.command, .shift]
            editing.insertItem(redo, at: 1)
            let copyResult = NSMenuItem(
                title: L10n.text("複製目前行答案"), action: #selector(FormattingTextView.copyCurrentCalculation(_:)),
                keyEquivalent: "c")
            copyResult.keyEquivalentModifierMask = [.command, .shift]
            editing.addItem(copyResult)
        }
        model.imagePastesFinished = { [weak self] succeeded in
            guard let self, waitingToTerminate else { return }
            waitingToTerminate = false
            NSApp.reply(toApplicationShouldTerminate: succeeded && model.flush())
        }
        let file = NSMenuItem(title: L10n.text("檔案"), action: nil, keyEquivalent: "")
        let fileMenu = NSMenu(title: L10n.text("檔案"))
        let create = NSMenuItem(title: L10n.text("新增筆記"), action: #selector(newNote), keyEquivalent: "n")
        create.target = self
        fileMenu.addItem(create)
        file.submenu = fileMenu
        NSApp.mainMenu?.insertItem(file, at: 1)
        panel = NotesPanel(
            contentRect: NSRect(
                x: 0, y: 0, width: 360, height: max(520, (NSScreen.main?.visibleFrame.height ?? 900) - 24)),
            styleMask: [.borderless, .resizable], backing: .buffered, defer: false)
        panel.title = "EdgeNotes"
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.minSize = NSSize(width: 320, height: 520)
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.contentView = NSHostingView(
            rootView: NotesView(
                model: model,
                loginItem: loginItem,
                collapse: { [weak self] in self?.collapse() },
                position: { [weak self] in
                    self?.position()
                    self?.rebuildBars()
                }))
        panel.contentView?.wantsLayer = true
        clipboardHotkey = GlobalHotKey { [weak self] in self?.clipboardNote() }
        if !clipboardHotkey.register(key: UInt32(kVK_ANSI_N), modifiers: UInt32(controlKey | optionKey | shiftKey)) {
            model.message = L10n.text("⌃⌥⇧N 已被佔用；可從新增選單貼上。")
        }
        hotkey = GlobalHotKey { [weak self] in self?.toggle() }
        if !hotkey.register(key: UInt32(kVK_ANSI_N), modifiers: UInt32(controlKey | shiftKey)) {
            model.failure = true
            model.message = L10n.text("⌃⇧N 已被佔用，可從 menu bar 開啟。")
        }
        status = NSStatusBar.system.statusItem(withLength: 26)
        let statusIcon = NSImage(
            systemSymbolName: "sidebar.right", accessibilityDescription: L10n.text("EdgeNotes — 側邊筆記"))?
            .withSymbolConfiguration(.init(pointSize: 16, weight: .medium))
        statusIcon?.size = NSSize(width: 16, height: 16)
        statusIcon?.isTemplate = true
        status.button?.image = statusIcon
        status.button?.imageScaling = .scaleProportionallyDown
        status.button?.toolTip = L10n.text("EdgeNotes — 開啟／收起側邊筆記")
        status.button?.setAccessibilityLabel(L10n.text("EdgeNotes — 側邊筆記"))
        status.button?.target = self
        status.button?.action = #selector(statusClick)
        status.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        keyboardMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.keyCode == 53 || (event.keyCode == 36 && event.modifierFlags.contains(.command)),
                self.panel.isKeyWindow, self.panel.attachedSheet == nil, self.model.incoming == nil,
                (self.panel.firstResponder as? NSTextView)?.hasMarkedText() != true
            else { return event }
            self.collapse()
            return nil
        }
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, !NSApp.isActive else { return }
                self.model.settingsVisible = false
                if UserDefaults.standard.bool(forKey: "hideOnDeactivate") { self.collapse(restore: false) }
            }
        }
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in self?.checkEdge() }
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
            self?.checkEdge()
            return event
        }
        let mouseDowns: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        mouseDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: mouseDowns) { [weak self] _ in
            self?.handleOutsideClick(at: NSEvent.mouseLocation, source: .otherApplication)
        }
        localMouseDownMonitor = NSEvent.addLocalMonitorForEvents(matching: mouseDowns) { [weak self] event in
            let point = event.window?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation
            self?.handleOutsideClick(at: point, source: .ownApplication)
            return event
        }
        NotificationCenter.default.addObserver(
            self, selector: #selector(menuStartedTracking), name: NSMenu.didBeginTrackingNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(menuStoppedTracking), name: NSMenu.didEndTrackingNotification, object: nil)
        observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.position()
                self?.rebuildBars()
            }
        }
        rebuildBars()
        ready = true
        if pendingShow {
            pendingShow = false
            show()
        }
    }
    private var side: EdgePanelSide {
        EdgePanelSide(rawValue: UserDefaults.standard.string(forKey: "side") ?? "right") ?? .right
    }
    private func targetScreen(on preferred: NSScreen? = nil) -> NSScreen? {
        let screens = NSScreen.screens
        let display = EdgePanelPlacement.displayID(
            explicit: preferred?.edgeDisplay?.id, anchor: anchoredDisplay, isShown: workflow.isShown,
            pointer: NSEvent.mouseLocation, displays: screens.compactMap(\.edgeDisplay))
        return screens.first { $0.edgeDisplay?.id == display }
    }
    private func layout(on screen: NSScreen) -> NSRect {
        let frame = EdgePanelPlacement.shownFrame(
            size: panel.frame.size, visibleFrame: screen.visibleFrame, side: side, fillHeight: fitsDisplayHeight)
        panel.minSize = NSSize(width: min(360, frame.width), height: min(520, frame.height))
        anchoredDisplay = screen.edgeDisplay?.id
        shownFrame = frame
        return frame
    }
    func position(on preferred: NSScreen? = nil) {
        cancelDwell()
        guard let screen = targetScreen(on: preferred) else { return }
        workflow.refreshGeometry()
        if !workflow.isShown { panel.orderOut(nil) }
        panel.setFrame(layout(on: screen), display: true)
    }
    func show(on screen: NSScreen? = nil) {
        cancelDwell()
        guard let screen = targetScreen(on: screen) else { return }
        let wasShown = workflow.isShown
        let movedDisplay = anchoredDisplay != screen.edgeDisplay?.id
        let frontmost = NSWorkspace.shared.frontmostApplication
        if frontmost?.processIdentifier != ProcessInfo.processInfo.processIdentifier { previousApp = frontmost }
        let transition = workflow.show(
            frontmostApplication: frontmost?.processIdentifier,
            ownApplication: ProcessInfo.processInfo.processIdentifier)
        let frame = layout(on: screen)
        if !panel.isVisible || movedDisplay {
            let start =
                wasShown
                ? frame : EdgePanelPlacement.hiddenFrame(shownFrame: frame, displayFrame: screen.frame, side: side)
            panel.setFrame(start, display: true)
        }
        AppSupport.show(panel)
        animate(to: frame, transition: transition)
    }
    func collapse(restore: Bool = true) {
        cancelDwell()
        guard workflow.isShown else { return }
        let blocked =
            model.incoming != nil || panel.attachedSheet != nil || NSApp.modalWindow != nil || panel.inLiveResize
            || (panel.firstResponder as? NSTextView)?.hasMarkedText() == true
        guard
            let transition = workflow.hide(
                reason: restore ? .manual : .deactivation, saved: !blocked && model.flush(),
                pinned: UserDefaults.standard.bool(forKey: "panelPinned"), blocksDismissal: blocked)
        else { return }
        model.settingsVisible = false
        let previous = previousApp
        previousApp = nil
        if let screen = NSScreen.screens.first(where: { $0.edgeDisplay?.id == anchoredDisplay }), let shownFrame {
            animate(
                to: EdgePanelPlacement.hiddenFrame(shownFrame: shownFrame, displayFrame: screen.frame, side: side),
                transition: transition, previous: previous)
        } else {
            finish(transition, previous: previous)
        }
    }
    private func handleOutsideClick(at point: NSPoint, source: NotesOutsideClickPolicy.Source) {
        let blocked =
            model.incoming != nil || trackedMenus > 0 || panel.attachedSheet != nil || NSApp.modalWindow != nil
            || panel.inLiveResize
            || (panel.firstResponder as? NSTextView)?.hasMarkedText() == true
        guard
            NotesOutsideClickPolicy.shouldDismiss(
                at: point, source: source, isShown: workflow.isShown,
                pinned: UserDefaults.standard.bool(forKey: "panelPinned"), blocksDismissal: blocked,
                protectedFrames: protectedClickFrames)
        else { return }
        // Do not reactivate the app that originally opened Notes: the click has
        // already chosen a new destination, including the Desktop or another note window.
        collapse(restore: false)
    }
    private var protectedClickFrames: [NSRect] {
        var frames = [panel.frame]
        frames.append(contentsOf: bars.filter(\.isVisible).map(\.frame))
        if let button = status.button, let window = button.window, window.isVisible {
            frames.append(window.convertToScreen(button.convert(button.bounds, to: nil)))
        }
        // Settings popovers, alerts, sheets and native picker windows can extend
        // beyond the sidebar. A click inside those controls remains an inside click.
        var excluded = Set(bars.map(\.windowNumber))
        excluded.insert(panel.windowNumber)
        if let window = status.button?.window { excluded.insert(window.windowNumber) }
        frames.append(
            contentsOf: NSApp.windows.filter { $0.isVisible && !excluded.contains($0.windowNumber) }.map(\.frame))
        return frames
    }
    @objc private func menuStartedTracking(_ notification: Notification) { trackedMenus += 1 }
    @objc private func menuStoppedTracking(_ notification: Notification) { trackedMenus = max(0, trackedMenus - 1) }
    private func animate(to frame: NSRect, transition: EdgePanelTransition, previous: NSRunningApplication? = nil) {
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            panel.setFrame(frame, display: true)
            finish(transition, previous: previous)
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(frame, display: true)
        } completionHandler: { [weak self] in
            Task { @MainActor in self?.finish(transition, previous: previous) }
        }
    }
    private func finish(_ transition: EdgePanelTransition, previous: NSRunningApplication?) {
        guard workflow.isCurrent(transition), !transition.isShown else { return }
        panel.orderOut(nil)
        let target = workflow.restorationTarget(
            for: transition, frontmostApplication: NSWorkspace.shared.frontmostApplication?.processIdentifier,
            ownApplication: ProcessInfo.processInfo.processIdentifier)
        if let previous, !previous.isTerminated, target == previous.processIdentifier { previous.activate(options: []) }
    }
    @objc func statusClick() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            let menu = NSMenu()
            for (title, selector) in [
                (L10n.text("展開／收起    ⌃⇧N"), #selector(toggle)), (L10n.text("新增筆記"), #selector(newNote)),
                (L10n.text("從剪貼簿新增    ⌃⌥⇧N"), #selector(clipboardNote)), (L10n.text("結束 EdgeNotes"), #selector(quit)),
            ] {
                let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
                item.target = self
                menu.addItem(item)
            }
            if let event = NSApp.currentEvent, let button = status.button {
                NSMenu.popUpContextMenu(menu, with: event, for: button)
            }
        } else {
            toggle()
        }
    }
    @objc func clipboardNote() {
        model.createFromClipboard()
        show()
    }
    func rebuildBars() {
        cancelDwell()
        for bar in bars {
            bar.orderOut(nil)
            bar.close()
        }
        bars.removeAll()
        let left = UserDefaults.standard.string(forKey: "side") == "left"
        for screen in NSScreen.screens {
            guard let display = screen.edgeDisplay else { continue }
            let side: EdgePanelSide = left ? .left : .right
            let bar = OpenBarPanel(frame: EdgePanelPlacement.openBarFrame(display: display, side: side))
            bar.contentView = OpenBarView(
                side: side,
                activate: { [weak self] in
                    guard let self else { return }
                    if self.workflow.isShown && self.anchoredDisplay == screen.edgeDisplay?.id {
                        self.collapse()
                    } else {
                        self.show(on: screen)
                    }
                },
                changeSide: { [weak self] in
                    UserDefaults.standard.set(left ? "right" : "left", forKey: "side")
                    self?.position()
                    self?.rebuildBars()
                })
            bar.orderFrontRegardless()
            bars.append(bar)
        }
    }
    @objc func toggle() { workflow.isShown ? collapse() : show() }
    @objc func newNote() {
        model.newNote()
        show()
    }
    @objc func quit() { NSApp.terminate(nil) }
    private func cancelDwell() {
        dwell?.cancel()
        dwell = nil
        dwellDisplay = nil
        dwellSide = nil
    }
    func checkEdge() {
        let side = self.side
        guard UserDefaults.standard.bool(forKey: "hotSide"), !workflow.isShown,
            let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }),
            let display = screen.edgeDisplay,
            EdgePanelPlacement.isAtEdge(NSEvent.mouseLocation, display: display, side: side)
        else {
            cancelDwell()
            return
        }
        if dwellDisplay != display.id || dwellSide != side { cancelDwell() }
        guard dwell == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.cancelDwell()
            guard UserDefaults.standard.bool(forKey: "hotSide"), !self.workflow.isShown, self.side == side,
                let current = NSScreen.screens.first(where: { $0.edgeDisplay?.id == display.id }),
                let currentDisplay = current.edgeDisplay,
                EdgePanelPlacement.isAtEdge(NSEvent.mouseLocation, display: currentDisplay, side: side)
            else { return }
            self.show(on: current)
        }
        dwell = work
        dwellDisplay = display.id
        dwellSide = side
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        collapse()
        return false
    }
    func windowWillStartLiveResize(_ notification: Notification) {
        heightBeforeResize = panel.frame.height
    }
    func windowDidEndLiveResize(_ notification: Notification) {
        if let heightBeforeResize, abs(panel.frame.height - heightBeforeResize) > 1 { fitsDisplayHeight = false }
        heightBeforeResize = nil
        if workflow.isShown { position() }
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if !model.pastingNoteIDs.isEmpty {
            waitingToTerminate = true
            model.message = L10n.text("圖片正在儲存，完成後會退出。")
            return .terminateLater
        }
        return model.flush() ? .terminateNow : .terminateCancel
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        show()
        return true
    }
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.isFileURL { model.receive(url) }
        if urls.allSatisfy(\.isFileURL), model.incoming == nil, !model.failure { return }
        guard ready else {
            pendingShow = true
            return
        }
        show()
    }
    func applicationWillTerminate(_ notification: Notification) {
        cancelDwell()
        if let keyboardMonitor { NSEvent.removeMonitor(keyboardMonitor) }
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        for bar in bars { bar.orderOut(nil) }
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        if let localMouseMonitor { NSEvent.removeMonitor(localMouseMonitor) }
        if let mouseDownMonitor { NSEvent.removeMonitor(mouseDownMonitor) }
        if let localMouseDownMonitor { NSEvent.removeMonitor(localMouseDownMonitor) }
        NotificationCenter.default.removeObserver(self, name: NSMenu.didBeginTrackingNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: NSMenu.didEndTrackingNotification, object: nil)
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }
}

extension NSScreen {
    fileprivate var edgeDisplay: EdgePanelDisplay? {
        guard let id = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
        return EdgePanelDisplay(id: id.uint32Value, frame: frame, visibleFrame: visibleFrame)
    }
}

@main enum NotesMain {
    @MainActor static func main() {
        if L10n.catalog.printDiagnosticsIfRequested() { return }
        let arguments = Set(CommandLine.arguments.dropFirst())
        if arguments.contains("--enable-login") && arguments.contains("--disable-login") {
            FileHandle.standardError.write(Data("Choose --enable-login or --disable-login.\n".utf8))
            exit(2)
        }
        if !arguments.isDisjoint(with: ["--enable-login", "--disable-login", "--login-status"]) {
            // Read or configure the signed main app before loading any notes or
            // waiting for AppKit launch events, including on a locked desktop.
            let item = NotesLoginItem()
            if arguments.contains("--enable-login") { item.setEnabled(true) }
            if arguments.contains("--disable-login") { item.setEnabled(false) }
            if let data = try? JSONSerialization.data(withJSONObject: [
                "status": item.status.rawValue, "summary": item.summary, "error": item.error,
            ]) {
                print(String(decoding: data, as: UTF8.self))
            }
            if !item.error.isEmpty { exit(1) }
            if arguments.contains("--startup-only") || arguments.contains("--login-status") { return }
        }
        let app = NSApplication.shared
        let delegate = NotesDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
