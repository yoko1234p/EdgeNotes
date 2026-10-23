import DeskCore
import SwiftUI

struct NotesIncomingView: View {
    @ObservedObject var model: NotesModel
    @State private var folderID: UUID?
    @State private var noteID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.text("存到 EdgeNotes")).font(.title2.weight(.semibold))
            Text(L10n.text("選擇資料夾和筆記，確認後儲存。")).foregroundStyle(.secondary)
            Form {
                Picker(L10n.text("資料夾"), selection: $folderID) {
                    if model.activeFolders.isEmpty {
                        Text(L10n.text("收件匣（儲存時建立）")).tag(UUID?.none)
                    }
                    ForEach(model.activeFolders) { folder in
                        Text(folder.name).tag(Optional(folder.id))
                    }
                }.accessibilityIdentifier("edgenotes.import.folder")
                Picker(L10n.text("筆記"), selection: $noteID) {
                    Text(L10n.text("新增筆記")).tag(UUID?.none)
                    ForEach(model.notesForImport(in: folderID)) { note in
                        Text(note.title).tag(Optional(note.id))
                    }
                }.accessibilityIdentifier("edgenotes.import.note")
            }.fixedSize(horizontal: false, vertical: true)
            Text(noteID == nil ? L10n.text("將在所選資料夾新增筆記。") : L10n.text("內容會加入筆記末尾，保留原有文字及圖片。"))
                .font(.caption).foregroundStyle(.secondary)
            ScrollView {
                Text(model.incoming?.text ?? "").textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }.frame(height: 180)
                .padding(10).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                .accessibilityIdentifier("edgenotes.import.preview")
            if !model.incomingError.isEmpty {
                Text(model.incomingError).foregroundStyle(.red).textSelection(.enabled)
                    .accessibilityIdentifier("edgenotes.import.error")
            }
            if model.incomingTexts.count > 1 {
                Text(L10n.text("另有 %1$@ 段文字等候處理。", String(describing: model.incomingTexts.count - 1)))
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button(L10n.text("取消此段"), role: .cancel) { model.cancelIncoming() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(noteID == nil ? L10n.text("建立筆記") : L10n.text("加入筆記")) {
                    if let incoming = model.incoming {
                        model.saveIncoming(incoming.id, folderID: folderID, noteID: noteID)
                    }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("edgenotes.import.save")
            }
        }.padding(24).frame(width: 440)
            .onAppear { chooseFolder() }
            .onChange(of: folderID) { _, _ in
                noteID = nil
                model.incomingError = ""
            }
            .onChange(of: noteID) { _, _ in model.incomingError = "" }
            .onChange(of: model.incoming?.id) { _, _ in
                if !model.activeFolders.contains(where: { $0.id == folderID }) { chooseFolder() }
            }
            .interactiveDismissDisabled()
    }

    private func chooseFolder() {
        folderID = model.activeFolders.first(where: { $0.id == model.folder })?.id ?? model.activeFolders.first?.id
        noteID = nil
    }
}
