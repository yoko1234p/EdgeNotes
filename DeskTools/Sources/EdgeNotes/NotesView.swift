import AppKit
import DeskCore
import DeskUI
import NotesCore
import SwiftUI
import UniformTypeIdentifiers

struct NotesView: View {
    @ObservedObject var model: NotesModel
    @ObservedObject var loginItem: NotesLoginItem
    var collapse: () -> Void
    var position: () -> Void
    @AppStorage("side") var side = "right"
    @AppStorage("hotSide") var hotSide = false
    @AppStorage("hideOnDeactivate") var hideOnDeactivate = false
    @AppStorage("panelPinned") var panelPinned = false
    @Environment(\.colorScheme) private var scheme
    @State private var addFolder = false
    @State private var renameFolder = false
    @State private var renamingID: UUID?
    @State private var deletingID: UUID?
    @State private var deleteFolderAlert = false
    @State private var emptyTrashAlert = false
    @AppStorage("calculations.enabled") private var calculationsEnabled = true
    @State private var folderName = ""
    @State private var dragged: UUID?
    @FocusState private var searchFocused: Bool
    private var accent: Color { NotesPalette.accent(scheme) }

    var body: some View {
        VStack(spacing: 12) {
            header
            VStack(spacing: 0) {
                if model.searchVisible {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField(
                            model.browsingFolders ? L10n.text("搜尋所有筆記") : L10n.text("搜尋筆記"),
                            text: Binding(get: { model.search }, set: { if model.flush() { model.search = $0 } })
                        ).textFieldStyle(.plain).focused($searchFocused).accessibilityIdentifier("notes.search")
                        if !model.search.isEmpty {
                            Button {
                                if model.flush() { model.search = "" }
                            } label: {
                                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                            }.buttonStyle(.plain).help(L10n.text("清除搜尋"))
                        }
                    }.padding(12).background(accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                        .padding(.horizontal, 12).padding(.top, 12)
                }
                if model.showingFolders {
                    folderList
                } else {
                    notesHeading
                    noteList
                }
                if model.failure {
                    Label(model.message, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.red).lineLimit(3)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16).padding(.bottom, 8)
                }
                footer
            }
            .background(NotesPalette.surface(scheme), in: RoundedRectangle(cornerRadius: 26))
            .overlay(RoundedRectangle(cornerRadius: 26).stroke(Color.primary.opacity(0.06), lineWidth: 1))
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .frame(minWidth: 320, minHeight: 520).tint(accent)
        .alert(L10n.text("新增資料夾"), isPresented: $addFolder) {
            TextField(L10n.text("資料夾名稱"), text: $folderName)
            Button(L10n.text("新增")) {
                model.addFolder(folderName)
                folderName = ""
            }
            .disabled(folderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button(L10n.text("取消"), role: .cancel) { folderName = "" }
        }
        .alert(L10n.text("重新命名資料夾"), isPresented: $renameFolder) {
            TextField(L10n.text("資料夾名稱"), text: $folderName)
            Button(L10n.text("儲存")) {
                if let id = renamingID { model.renameFolder(id, to: folderName) }
                folderName = ""
            }
            .disabled(folderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button(L10n.text("取消"), role: .cancel) { folderName = "" }
        }
        .alert(L10n.text("刪除資料夾？"), isPresented: $deleteFolderAlert) {
            Button(L10n.text("刪除資料夾"), role: .destructive) {
                if let id = deletingID { _ = model.deleteFolder(id) }
                deletingID = nil
            }
            Button(L10n.text("取消"), role: .cancel) { deletingID = nil }
        } message: {
            Text(L10n.text("資料夾及當中的筆記會移到回收筒，可還原；附件會保留。"))
        }
        .alert(L10n.text("清空回收筒？"), isPresented: $emptyTrashAlert) {
            Button(L10n.text("清空回收筒"), role: .destructive) { model.emptyTrash() }
            Button(L10n.text("取消"), role: .cancel) {}
        } message: {
            Text(
                L10n.text(
                    "刪除 %1$@ 張筆記及 %2$@ 個資料夾，並清除內部快照的相關內容。已匯出的備份不受影響。", String(describing: model.trashCount),
                    String(describing: model.deletedFolders.count)))
        }
        .sheet(isPresented: Binding(get: { model.incoming != nil }, set: { if !$0 { model.cancelIncoming() } })) {
            NotesIncomingView(model: model)
        }
        .sheet(isPresented: $model.templatesVisible) { NotesTemplatesView(model: model) }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Button(action: collapse) {
                Text("EdgeNotes").font(.system(size: 20, weight: .bold)).foregroundStyle(accent)
            }.buttonStyle(.plain).help(L10n.text("收起 · ⌃⇧N")).accessibilityIdentifier("notes.collapse")
            Spacer(minLength: 4)
            Button {
                if model.toggleSearch(), model.searchVisible { searchFocused = true }
            } label: {
                Image(systemName: "magnifyingglass")
            }
            .buttonStyle(SidebarCircleStyle(active: model.searchVisible))
            .help(L10n.text("搜尋筆記 · ⌘F")).keyboardShortcut("f").accessibilityIdentifier("notes.search-toggle")
            Menu {
                ForEach(model.templates) { template in
                    Button(template.name) { model.newNote(template.render()) }
                }
                Divider()
                Button(L10n.text("管理範本…")) { model.templatesVisible = true }
            } label: {
                Image(systemName: "doc.badge.plus")
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 26)
            .help(L10n.text("用範本新增筆記")).disabled(model.incoming != nil)
            .accessibilityIdentifier("notes.templates")
            if model.showingFolders {
                Button {
                    folderName = ""
                    addFolder = true
                } label: {
                    Image(systemName: "plus").font(.system(size: 22))
                }
                .buttonStyle(SidebarCircleStyle()).help(L10n.text("新增資料夾 · ⌘⌥N"))
                .keyboardShortcut("n", modifiers: [.command, .option]).accessibilityIdentifier("notes.folder-add")
            } else {
                Button {
                    model.newNote()
                } label: {
                    Image(systemName: "plus").font(.system(size: 22))
                }
                .buttonStyle(SidebarCircleStyle()).help(L10n.text("新增筆記 · ⌘N")).accessibilityIdentifier("notes.new")
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 13)
        .background(NotesPalette.header(scheme), in: RoundedRectangle(cornerRadius: 24))
        .overlay(RoundedRectangle(cornerRadius: 24).stroke(Color.primary.opacity(0.08), lineWidth: 1))
    }

    private var folderList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(model.activeFolders) { folder in
                    HStack(spacing: 0) {
                        SidebarFolderRow(name: folder.name, count: model.noteCount(in: folder.id)) {
                            _ = model.openFolder(folder.id)
                        }.accessibilityIdentifier("notes.folder." + folder.id.uuidString)
                        Menu {
                            folderActions(folder)
                        } label: {
                            Image(systemName: "ellipsis")
                        }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 22)
                        .help(L10n.text("開啟、重新命名或刪除資料夾"))
                        .accessibilityIdentifier("notes.folder-menu." + folder.id.uuidString)
                    }.contextMenu { folderActions(folder) }
                }
            }.padding(.horizontal, 8).padding(.top, 12)
        }.accessibilityIdentifier("notes.folders")
    }

    @ViewBuilder private func folderActions(_ folder: NoteFolder) -> some View {
        Button(L10n.text("開啟資料夾")) { _ = model.openFolder(folder.id) }
        Button(L10n.text("重新命名…")) {
            folderName = folder.name
            renamingID = folder.id
            renameFolder = true
        }
        Divider()
        Button(L10n.text("刪除資料夾…"), role: .destructive) {
            deletingID = folder.id
            deleteFolderAlert = true
        }
    }

    private var notesHeading: some View {
        HStack(spacing: 8) {
            Button {
                _ = model.showFolders()
            } label: {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(.plain).foregroundStyle(accent).help(L10n.text("返回資料夾")).accessibilityIdentifier("notes.back")
            Text(
                model.trash
                    ? L10n.text("回收筒")
                    : !model.search.isEmpty
                        ? L10n.text("搜尋結果")
                        : model.document.folders.first(where: { $0.id == model.folder })?.name ?? L10n.text("全部筆記")
            )
            .font(.system(size: 14, weight: .semibold)).lineLimit(1)
            Spacer(minLength: 4)
            Text(String(model.visible.count)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
            if model.trash {
                Button(L10n.text("清空")) { emptyTrashAlert = true }
                    .disabled((model.trashCount == 0 && model.deletedFolders.isEmpty) || !model.pastingNoteIDs.isEmpty)
                    .accessibilityIdentifier("notes.empty-trash")
            }
            if !model.trash, let folder = model.activeFolders.first(where: { $0.id == model.folder }) {
                Menu {
                    folderActions(folder)
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 22)
                .accessibilityIdentifier("notes.folder-actions")
            }
        }.padding(.horizontal, 18).padding(.top, 16).padding(.bottom, 4)
    }

    private var noteList: some View {
        ScrollViewReader { scroll in
            ScrollView {
                LazyVStack(spacing: 12) {
                    if model.trash {
                        ForEach(model.deletedFolders) { folder in
                            HStack(spacing: 10) {
                                Image(systemName: "folder").foregroundStyle(accent)
                                Text(folder.name).lineLimit(1)
                                Spacer()
                                Button(L10n.text("還原資料夾")) { model.restoreFolder(folder.id) }
                                    .accessibilityIdentifier("notes.folder-restore." + folder.id.uuidString)
                            }.padding(12).background(accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                        }
                    }
                    if model.visible.isEmpty && (!model.trash || model.deletedFolders.isEmpty) {
                        VStack(spacing: 14) {
                            Image(
                                systemName: model.trash
                                    ? "trash" : model.search.isEmpty ? "square.and.pencil" : "magnifyingglass"
                            )
                            .font(.system(size: 30)).foregroundStyle(accent.opacity(0.65))
                            Text(
                                model.trash
                                    ? L10n.text("回收筒是空的")
                                    : model.search.isEmpty ? L10n.text("隨手記低，繼續工作") : L10n.text("找不到符合的筆記")
                            )
                            .font(.callout).foregroundStyle(.secondary)
                            if !model.trash && model.search.isEmpty {
                                Button(L10n.text("新增筆記")) { model.newNote() }.buttonStyle(.borderedProminent)
                                Text(L10n.text("⌘N 新筆記 · ⌃⌥⇧N 剪貼簿新增")).font(.caption).foregroundStyle(.secondary)
                            }
                        }.frame(maxWidth: .infinity).padding(.vertical, 54)
                    }
                    ForEach(model.visible) { note in
                        NoteCard(model: model, note: note).id(note.id)
                            .onDrag {
                                dragged = note.id
                                return NSItemProvider(object: note.id.uuidString as NSString)
                            }
                            .onDrop(of: [.text], isTargeted: nil) { providers in
                                guard let source = dragged, let provider = providers.first else { return false }
                                provider.loadObject(ofClass: NSString.self) { object, _ in
                                    guard let identifier = object as? String, identifier == source.uuidString else {
                                        return
                                    }
                                    Task { @MainActor in
                                        model.move(source, before: note.id)
                                        dragged = nil
                                    }
                                }
                                return true
                            }
                    }
                }.padding(12)
            }.onChange(of: model.pastedImageID) { _, id in
                if let id { scroll.scrollTo("notes.image." + id.uuidString, anchor: .center) }
            }.onChange(of: model.selected) { _, id in
                if let id { withAnimation(.easeOut(duration: 0.15)) { scroll.scrollTo(id, anchor: .center) } }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button {
                _ = model.toggleTrash()
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(SidebarCircleStyle(active: model.trash, diameter: 32))
            .help(L10n.text("回收筒 · %1$@ 張筆記", String(describing: model.trashCount))).accessibilityIdentifier(
                "notes.trash")
            Menu {
                Button(L10n.text("全部筆記")) { _ = model.openFolder(nil) }
                Button(L10n.text("新增筆記")) { model.newNote() }.keyboardShortcut("n")
                Button(L10n.text("新增資料夾…")) {
                    folderName = ""
                    addFolder = true
                }
                Divider()
                Button(L10n.text("從剪貼簿新增")) { model.createFromClipboard() }
                Button(L10n.text("匯入文字檔…")) { model.importTextFile() }
                Divider()
                Button(L10n.text("匯出完整備份…")) { model.exportBackup() }
                Button(L10n.text("合併備份…")) { model.importBackup() }
                Divider()
                Button(L10n.text("收起 · ⌃⇧N"), action: collapse)
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 15)).frame(width: 32, height: 32)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 32, height: 32)
            .overlay(Circle().stroke(Color.primary.opacity(0.10), lineWidth: 1)).help(L10n.text("更多操作"))
            .accessibilityIdentifier("notes.more")
            Spacer(minLength: 4)
            Image(systemName: "checkmark.circle").font(.system(size: 11)).foregroundStyle(.secondary)
                .help(model.message).accessibilityLabel(model.message)
            Button {
                panelPinned.toggle()
            } label: {
                Image(systemName: panelPinned ? "pin.fill" : "pin")
            }
            .buttonStyle(SidebarCircleStyle(active: panelPinned, diameter: 32))
            .help(panelPinned ? L10n.text("取消固定面板") : L10n.text("固定面板，點擊外面或切換 App 時保持開啟"))
            .accessibilityLabel(panelPinned ? L10n.text("取消固定面板") : L10n.text("固定面板")).accessibilityIdentifier(
                "notes.panel-pin")
            NotesSettingsButton(presented: $model.settingsVisible, contents: AnyView(settingsContents))
                .frame(width: 32, height: 32)
        }
        .padding(8).background(NotesPalette.header(scheme).opacity(0.7), in: Capsule())
        .overlay(Capsule().stroke(Color.primary.opacity(0.08), lineWidth: 1)).padding(8)
    }

    private var settingsContents: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(L10n.text("側邊與快速操作")).font(.headline)
                Picker(L10n.text("停靠"), selection: $side) {
                    Text(L10n.text("左邊")).tag("left")
                    Text(L10n.text("右邊")).tag("right")
                }
                .pickerStyle(.segmented).onChange(of: side) { _, _ in position() }.accessibilityIdentifier("notes.side")
                Toggle(L10n.text("邊緣停留 0.5 秒展開"), isOn: $hotSide).accessibilityIdentifier("notes.hot-side")
                Toggle(L10n.text("切換到其他 App 時收起"), isOn: $hideOnDeactivate).accessibilityIdentifier("notes.auto-hide")
                Text(L10n.text("點擊面板外會收起；固定面板時保持開啟，收起按鈕與快捷鍵仍可使用。"))
                    .font(.caption).foregroundStyle(.secondary)
                Text(L10n.text("⌃⇧N 展開／收起 · ⌃⌥⇧N 剪貼簿新增\n⌘F 搜尋 · ⌘↵ 儲存及收起\n⌘B 粗體 · ⌘I 斜體 · ⌘T 待辦"))
                    .font(.caption).foregroundStyle(.secondary)
                Divider()
                Text(L10n.text("筆記計算")).font(.headline)
                Toggle(L10n.text("自動將計算答案寫入文字"), isOn: $calculationsEnabled)
                    .accessibilityIdentifier("notes.calculations.enabled")
                Text(L10n.text("輸入 4 cm in inches、10% off $99.99、em = 14px；支援變數、百分比及數學函數。"))
                    .font(.caption).foregroundStyle(.secondary)
                Text(L10n.text("答案係筆記實體文字，可一齊選取、複製及儲存；⌘⇧C 只複製目前行較高精度答案。"))
                    .font(.caption).foregroundStyle(.secondary)
                Text(L10n.text("句尾亦可計算，例如 i will see 1 mm in m，會接上（0.001 m）。"))
                    .font(.caption).foregroundStyle(.secondary)
                Button(model.exchangeRates.busy ? L10n.text("正在更新…") : L10n.text("更新匯率")) {
                    model.exchangeRates.refresh()
                }
                .disabled(model.exchangeRates.busy).accessibilityIdentifier("notes.rates.refresh")
                Text(model.exchangeRates.message).font(.caption).foregroundStyle(.secondary)
                Divider()
                Text(L10n.text("啟動")).font(.headline)
                Toggle(
                    L10n.text("開機登入後自動啟動"),
                    isOn: Binding(get: { loginItem.isRegistered }, set: { loginItem.setEnabled($0) })
                ).accessibilityIdentifier("notes.login.enabled")
                Text(loginItem.summary).font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("notes.login.status")
                if !loginItem.error.isEmpty {
                    Text(loginItem.error).font(.caption).foregroundStyle(.red)
                        .accessibilityIdentifier("notes.login.error")
                }
                if loginItem.status == .requiresApproval {
                    Button(L10n.text("打開登入項目設定")) { loginItem.showSettings() }
                        .accessibilityIdentifier("notes.login.settings")
                }
                Divider()
                Button(L10n.text("匯出完整備份…")) { model.exportBackup() }
                Button(L10n.text("合併備份…")) { model.importBackup() }
                Text(L10n.text("本機儲存；尚未提供 iCloud 同步。")).font(.caption).foregroundStyle(.secondary)
            }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
        }.frame(width: 330, height: 490)
            .onAppear { loginItem.refresh() }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                loginItem.refresh()
            }
    }
}

struct NoteCard: View {
    @ObservedObject var model: NotesModel
    let note: DeskNote
    @StateObject private var editor = NoteEditorController()
    @AppStorage("calculations.enabled") private var calculationsEnabled = true
    @Environment(\.colorScheme) private var colorScheme
    private var editing: Bool { model.selected == note.id && note.folded != true && !model.preview }
    private var text: String { model.selected == note.id ? model.draft : note.text }
    private var tint: Color {
        switch note.color {
        case "yellow": return .yellow
        case "green": return .green
        case "blue": return .blue
        case "pink": return .pink
        default: return .secondary
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Button {
                    model.change(note.id) { $0.folded = !($0.folded ?? false) }
                } label: {
                    Image(systemName: note.folded == true ? "chevron.right" : "chevron.down")
                }.help(L10n.text("摺疊／展開筆記")).accessibilityIdentifier("notes.fold." + note.id.uuidString)
                if note.pinned { Image(systemName: "pin.fill").foregroundStyle(NotesPalette.accent(colorScheme)) }
                if note.favorite == true {
                    Image(systemName: "star.fill").foregroundStyle(.yellow).help(L10n.text("常用收藏目的地"))
                }
                Text(note.folded == true ? note.title : "")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                if editing {
                    Button(L10n.text("完成")) { if model.flush() { model.select(nil) } }.font(.caption).help(
                        L10n.text("已自動儲存；結束編輯"))
                }
            }.buttonStyle(.borderless)
            if note.folded != true {
                if editing {
                    HStack(spacing: 12) {
                        Button("B") { editor.apply(.bold) }.fontWeight(.bold).help(L10n.text("粗體 · ⌘B"))
                            .accessibilityIdentifier(
                                "notes.format-bold")
                        Button("I") { editor.apply(.italic) }.italic().help(L10n.text("斜體 · ⌘I"))
                        Button {
                            editor.apply(.heading)
                        } label: {
                            Image(systemName: "textformat.size.larger")
                        }.help(L10n.text("標題"))
                        Button {
                            editor.apply(.bullet)
                        } label: {
                            Image(systemName: "list.bullet")
                        }.help(L10n.text("清單 · ⌘L"))
                        Button {
                            editor.apply(.task)
                        } label: {
                            Image(systemName: "checklist")
                        }.help(L10n.text("待辦 · ⌘T"))
                        Button {
                            editor.apply(.code)
                        } label: {
                            Image(systemName: "chevron.left.forwardslash.chevron.right")
                        }.help(L10n.text("行內程式碼"))
                        Spacer(minLength: 0)
                    }.buttonStyle(.borderless).font(.system(size: 12)).foregroundStyle(.secondary)
                        .padding(7).background(.quaternary.opacity(0.5), in: Capsule())
                    InlineNoteEditor(
                        text: Binding(get: { model.draft }, set: { model.updateDraft(note.id, $0) }),
                        controller: editor, attachments: note.attachments,
                        calculationsEnabled: calculationsEnabled, rates: model.exchangeRates.snapshot?.rates ?? [:],
                        calculationAnnotations: model.draftCalculationAnnotations,
                        contentChanged: { text, annotations in
                            guard model.selected == note.id else { return }
                            model.updateDraft(note.id, text, calculationAnnotations: annotations)
                        },
                        pasteImages: { sources, currentText, selection in
                            model.pasteImageSources(
                                sources, into: note.id, text: currentText, selection: selection,
                                committed: { [weak controller = editor] before, after, attachments, ids in
                                    controller?.pasted(before: before, after: after, attachments: attachments, ids: ids)
                                })
                        },
                        pasteFailure: model.pasteFailed
                    )
                    .frame(
                        height: min(
                            350,
                            max(
                                90,
                                CGFloat(
                                    String(text.prefix(12_000)).components(separatedBy: "\n").reduce(0) {
                                        $0 + max(1, ($1.count + 27) / 28)
                                    }) * 22 + 20))
                    )
                } else {
                    NoteContentPreview(
                        model: model, note: note, text: text, enabled: calculationsEnabled,
                        calculationAnnotations: model.selected == note.id
                            ? model.draftCalculationAnnotations : note.calculationAnnotations ?? [])
                }
                if model.pastingNoteIDs.contains(note.id) { ProgressView(L10n.text("正在貼上圖片…")).font(.caption) }
                if !note.attachments.isEmpty {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(
                            note.attachments.filter { attachment in
                                note.usesInlineImages != true
                                    || UTType(filenameExtension: (attachment.name as NSString).pathExtension)?.conforms(
                                        to: .image) != true
                            }
                        ) { attachment in
                            if UTType(filenameExtension: (attachment.name as NSString).pathExtension)?.conforms(
                                to: .image) == true
                            {
                                NoteImageView(attachment: attachment) { model.exportAttachment(attachment) }
                                    .id("notes.image." + attachment.id.uuidString)
                                    .contextMenu {
                                        Button(L10n.text("另存圖片…")) { model.exportAttachment(attachment) }
                                        Button(L10n.text("移除圖片"), role: .destructive) {
                                            model.change(note.id) {
                                                $0.attachments.removeAll { $0.id == attachment.id }
                                            }
                                        }
                                    }
                            } else {
                                Button {
                                    model.exportAttachment(attachment)
                                } label: {
                                    Label(attachment.name, systemImage: "paperclip").lineLimit(1)
                                }
                                .contextMenu {
                                    Button(L10n.text("移除附件"), role: .destructive) {
                                        model.change(note.id) { $0.attachments.removeAll { $0.id == attachment.id } }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            HStack(spacing: 12) {
                Button {
                    model.select(note.id)
                    model.change(note.id) { $0.folded = false }
                    model.preview = false
                } label: {
                    Text("Aa").font(.system(size: 12, weight: .semibold))
                }
                .help(L10n.text("編輯／格式化")).accessibilityIdentifier("notes.edit." + note.id.uuidString)
                Menu {
                    Button(L10n.text("複製全文")) { AppSupport.copy(text) }
                    Button(L10n.text("匯出文字…")) { AppSupport.export(text, name: L10n.text("筆記.md")) }
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }.menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 20)
                Menu {
                    actions
                } label: {
                    Image(systemName: "gearshape")
                }.menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 20)
                    .accessibilityIdentifier("notes.actions." + note.id.uuidString)
                Spacer(minLength: 2)
                Text(note.updatedAt.formatted(date: .numeric, time: .shortened)).font(.system(size: 10))
                    .foregroundStyle(.secondary).lineLimit(1)
            }.buttonStyle(.borderless).foregroundStyle(.secondary)
            NoteSourceTagsView(model: model, note: note)
        }.padding(14).background(
            tint.opacity(note.color == nil ? 0.07 : colorScheme == .dark ? 0.28 : 0.16),
            in: RoundedRectangle(cornerRadius: 12)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12).stroke(
                editing ? NotesPalette.accent(colorScheme).opacity(0.6) : tint.opacity(0.18)))
    }
    @ViewBuilder private var actions: some View {
        Button(L10n.text("編輯")) {
            model.select(note.id)
            model.change(note.id) { $0.folded = false }
            model.preview = false
        }
        Button(note.pinned ? L10n.text("取消置頂") : L10n.text("置頂")) { model.change(note.id) { $0.pinned.toggle() } }
        Button(note.favorite == true ? L10n.text("取消常用收藏目的地") : L10n.text("設為常用收藏目的地")) { model.toggleFavorite(note) }
            .disabled(note.trashed)
        Button(L10n.text("儲存為範本…")) {
            model.select(note.id)
            model.templatesVisible = true
        }
        Button(note.folded == true ? L10n.text("展開") : L10n.text("摺疊")) {
            model.change(note.id) { $0.folded = !($0.folded ?? false) }
        }
        Menu(L10n.text("顏色")) {
            ForEach(["default", "yellow", "green", "blue", "pink"], id: \.self) { color in
                Button(
                    [
                        "default": L10n.text("預設"), "yellow": L10n.text("黃"), "green": L10n.text("綠"),
                        "blue": L10n.text("藍"), "pink": L10n.text("粉紅"),
                    ][color]!
                ) {
                    model.change(note.id) { $0.color = color }
                }
            }
        }
        Menu(L10n.text("移至資料夾")) {
            ForEach(model.activeFolders) { folder in
                Button(folder.name) {
                    model.change(note.id) {
                        $0.folderID = folder.id
                        $0.trashedWithFolder = nil
                    }
                }
            }
        }
        Divider()
        Button(L10n.text("複製全文")) { AppSupport.copy(text) }
        Button(L10n.text("新增附件…")) {
            model.select(note.id)
            if model.selected == note.id { model.attach() }
        }
        Button(L10n.text("匯出文字…")) { AppSupport.export(text, name: L10n.text("筆記.md")) }
        Button(note.trashed ? L10n.text("還原筆記") : L10n.text("移到回收筒"), role: note.trashed ? nil : .destructive) {
            model.toggleNoteTrash(note.id)
        }
    }
}
