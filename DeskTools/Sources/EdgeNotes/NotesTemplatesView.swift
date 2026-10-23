import DeskCore
import NotesCore
import SwiftUI

struct NotesTemplatesView: View {
    @ObservedObject var model: NotesModel
    @Environment(\.dismiss) private var dismiss
    @State private var editing: UUID?
    @State private var name = ""
    @State private var text = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L10n.text("筆記範本")).font(.title2.bold())
                Spacer()
                Button(L10n.text("完成")) { dismiss() }
            }
            Text(L10n.text("{{date}} 日期 · {{time}} 時間 · {{title}} 範本名稱")).font(.caption).foregroundStyle(.secondary)
            List(model.templates) { template in
                HStack {
                    Text(template.name)
                    Spacer()
                    Button(L10n.text("使用")) {
                        model.newNote(template.render())
                        dismiss()
                    }
                    Button(L10n.text("編輯")) {
                        editing = model.customTemplates.contains(where: { $0.id == template.id }) ? template.id : nil
                        name = template.name
                        text = template.text
                    }
                    if model.customTemplates.contains(where: { $0.id == template.id }) {
                        Button(role: .destructive) {
                            model.deleteTemplate(template.id)
                        } label: {
                            Image(systemName: "trash")
                        }
                    }
                }
            }.frame(height: 150)
            Divider()
            TextField(L10n.text("範本名稱"), text: $name).textFieldStyle(.roundedBorder).accessibilityIdentifier(
                "notes.template.name")
            TextEditor(text: $text).font(.body.monospaced()).frame(minHeight: 150).border(.quaternary)
                .accessibilityIdentifier("notes.template.body")
            if !model.templateError.isEmpty { Text(model.templateError).font(.caption).foregroundStyle(.red) }
            HStack {
                Button(L10n.text("新增範本")) {
                    editing = nil
                    name = ""
                    text = ""
                }
                Button(L10n.text("使用目前筆記文字")) {
                    editing = nil
                    name = model.selectedNote?.title ?? L10n.text("新範本")
                    text = NoteImagePlacement.blocks(model.draft).compactMap { block -> String? in
                        if case .text(let value) = block { return value }
                        return nil
                    }.joined()
                }
                .disabled(model.selectedNote == nil)
                Spacer()
                Button(L10n.text("儲存範本")) { model.saveTemplate(name: name, text: text, replacing: editing) }
                    .disabled(
                        name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || text.isEmpty
                            || !model.templateError.isEmpty
                    )
                    .accessibilityIdentifier("notes.template.save")
            }
        }.padding(20).frame(width: 510, height: 490)
    }
}

struct NoteSourceTagsView: View {
    @ObservedObject var model: NotesModel
    let note: DeskNote
    var body: some View {
        let tags = model.tags(for: note)
        let links = (note.collectionSources ?? []).compactMap(\.source).filter { $0.url != nil }
        if !tags.isEmpty || !links.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                if !tags.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 5) {
                            ForEach(tags, id: \.self) { tag in
                                Button("#" + tag) { model.filterTag(tag) }
                                    .font(.caption2).buttonStyle(.bordered).controlSize(.mini)
                            }
                        }
                    }
                }
                ForEach(Array(links.suffix(3).enumerated()), id: \.offset) { _, source in
                    if let address = source.url, let url = URL(string: address) {
                        Link(destination: url) {
                            Label(
                                source.title?.isEmpty == false ? source.title! : (url.host ?? L10n.text("來源")),
                                systemImage: "link"
                            )
                            .font(.caption2).lineLimit(1)
                        }.help(address)
                    }
                }
            }
        }
    }
}
