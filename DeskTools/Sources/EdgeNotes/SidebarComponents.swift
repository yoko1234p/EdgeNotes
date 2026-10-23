import AppKit
import DeskCore
import SwiftUI

enum NotesPalette {
    static func surface(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0.095, green: 0.108, blue: 0.133) : Color(red: 0.97, green: 0.977, blue: 0.988)
    }
    static func header(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0.115, green: 0.133, blue: 0.163) : .white
    }
    static func accent(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0.57, green: 0.69, blue: 0.97) : Color(red: 0.20, green: 0.38, blue: 0.75)
    }
}

struct NotesSettingsButton: NSViewRepresentable {
    @Binding var presented: Bool
    let contents: AnyView
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSButton {
        let button = NSButton()
        button.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: L10n.text("設定"))
        button.imagePosition = .imageOnly
        button.isBordered = false
        button.wantsLayer = true
        button.layer?.cornerRadius = 16
        button.layer?.borderWidth = 1
        button.layer?.borderColor = NSColor.labelColor.withAlphaComponent(0.1).cgColor
        button.setAccessibilityIdentifier("notes.settings")
        button.setAccessibilityLabel(L10n.text("設定"))
        button.toolTip = L10n.text("設定")
        button.target = context.coordinator
        button.action = #selector(Coordinator.toggle)
        return button
    }
    func updateNSView(_ button: NSButton, context: Context) {
        let coordinator = context.coordinator
        coordinator.owner = self
        coordinator.controller.rootView = contents
        button.contentTintColor = presented ? .systemBlue : .labelColor
        if presented, !coordinator.popover.isShown, button.window?.isVisible == true {
            coordinator.popover.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
        } else if !presented, coordinator.popover.isShown {
            coordinator.popover.close()
        }
    }
    static func dismantleNSView(_ button: NSButton, coordinator: Coordinator) { coordinator.popover.close() }
    @MainActor final class Coordinator: NSObject, NSPopoverDelegate {
        var owner: NotesSettingsButton
        let popover = NSPopover()
        let controller: NSHostingController<AnyView>
        init(_ owner: NotesSettingsButton) {
            self.owner = owner
            controller = NSHostingController(rootView: owner.contents)
            super.init()
            popover.contentViewController = controller
            popover.contentSize = NSSize(width: 330, height: 490)
            popover.behavior = .transient
            popover.animates = false
            popover.delegate = self
        }
        @objc func toggle() { owner.presented.toggle() }
        func popoverDidClose(_ notification: Notification) {
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.popover.isShown, self.owner.presented else { return }
                self.owner.presented = false
            }
        }
    }
}

struct SidebarCircleStyle: ButtonStyle {
    var active = false
    var diameter: CGFloat = 34
    @Environment(\.colorScheme) private var scheme
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .regular))
            .frame(width: diameter, height: diameter)
            .foregroundStyle(active ? NotesPalette.accent(scheme) : Color.primary.opacity(0.85))
            .background(
                active || configuration.isPressed ? NotesPalette.accent(scheme).opacity(0.14) : .clear, in: Circle()
            )
            .overlay(Circle().stroke(Color.primary.opacity(0.10), lineWidth: 1))
            .contentShape(Circle())
    }
}

struct SidebarFolderRow: View {
    let name: String
    let count: Int
    var open: () -> Void
    @Environment(\.colorScheme) private var scheme
    @State private var hovered = false
    var body: some View {
        Button(action: open) {
            HStack(spacing: 12) {
                Image(systemName: "folder").font(.system(size: 19)).foregroundStyle(NotesPalette.accent(scheme))
                Text(name).font(.system(size: 14, weight: .medium)).lineLimit(1)
                Spacer(minLength: 8)
                Text(String(count)).font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14).frame(height: 42)
            .background(
                hovered ? NotesPalette.accent(scheme).opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 10)
            )
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain).onHover { hovered = $0 }
        .accessibilityLabel(L10n.text("%1$@，%2$@ 張筆記", String(describing: name), String(describing: count)))
    }
}
