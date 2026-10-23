import AppKit
import DeskCore
import LocalWorkflowKit
import SwiftUI

public struct NoteDestinationsMenu: View {
    let text: String
    let source: DraftSource?
    @State private var destinations: [NoteDestination] = []
    @State private var loadError = ""
    public init(text: String, source: DraftSource? = nil) {
        self.text = text
        self.source = source
    }
    public var body: some View {
        Menu {
            if destinations.isEmpty {
                Text(loadError.isEmpty ? L10n.text("在 EdgeNotes 將筆記設為常用收藏目的地") : loadError)
            }
            ForEach(destinations) { note in
                Button(note.folderName + " › " + note.title) {
                    AppSupport.sendDraft(.init(kind: .note, text: text, source: source, targetNoteID: note.id))
                }
            }
            Divider()
            Button(L10n.text("選擇其他資料夾／筆記…")) { AppSupport.sendDraft(.init(kind: .note, text: text, source: source)) }
        } label: {
            Label(L10n.text("收藏到筆記"), systemImage: "star.bubble")
        }
        .onAppear(perform: refresh)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refresh()
        }
        .onReceive(DistributedNotificationCenter.default().publisher(for: WorkflowFiles.destinationsDidChange)) { _ in
            refresh()
        }
    }
    private func refresh() {
        do {
            destinations = try WorkflowFiles.destinations().notes
            loadError = ""
        } catch {
            destinations = []
            loadError = error.localizedDescription
        }
    }
}
