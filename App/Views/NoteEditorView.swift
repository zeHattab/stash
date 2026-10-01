import SwiftUI
import StashCore

struct NoteEditorView: View {
    let model: AppModel
    let original: VaultItem
    var onCollect: ((VaultItem) -> Void)? = nil

    @Environment(\.dismiss) private var dismiss

    @State private var title: String
    @State private var text: String
    @State private var favorite: Bool
    @State private var confirmDelete = false

    init(model: AppModel, original: VaultItem, onCollect: ((VaultItem) -> Void)? = nil) {
        self.model = model
        self.original = original
        self.onCollect = onCollect
        _title = State(initialValue: original.title)
        _text = State(initialValue: original.notes)
        _favorite = State(initialValue: original.favorite)
    }

    private var isExisting: Bool { model.items.contains { $0.id == original.id } }

    var body: some View {
        Form {
            Section {
                TextField("Название", text: $title)
                Toggle("Избранное", isOn: $favorite)
            }
            Section("Текст") {
                TextField("Текст заметки", text: $text, axis: .vertical)
                    .lineLimit(3...20)
            }
            if isExisting {
                Section {
                    Button("Удалить запись", role: .destructive) { confirmDelete = true }
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .navigationTitle(isExisting ? "Заметка" : "Новая заметка")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Готово") { save() }
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .alert("Удалить запись?", isPresented: $confirmDelete) {
            Button("Удалить", role: .destructive) {
                Task { try? await model.delete(original.id); dismiss() }
            }
            Button("Отмена", role: .cancel) {}
        }
    }

    private func save() {
        var item = original
        item.title = title.trimmingCharacters(in: .whitespaces)
        item.notes = text
        item.favorite = favorite
        item.kind = .secureNote
        if let onCollect {
            onCollect(item)
            dismiss()
        } else {
            Task { try? await model.save(item); dismiss() }
        }
    }
}
