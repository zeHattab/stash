import SwiftUI
import StashCore

/// Экран наполнения ложного сейфа. Записи собираются ЛОКАЛЬНО (без захардкоженных
/// примеров) и передаются в enableSecondPassword при завершении. Кнопки-подсказки
/// открывают пустой редактор нужного типа — значения пользователь придумывает сам.
struct DecoyFillView: View {
    let model: AppModel
    let secondPassword: String

    @Environment(\.dismiss) private var dismiss

    @State private var collected: [VaultItem] = []
    @State private var editing: VaultItem?
    @State private var decoyRecoveryKey: String?
    @State private var showSwitchOffer = false
    @State private var working = false
    @State private var errorText: String?

    var body: some View {
        Form {
            Section {
                Text("Наполните ложный сейф правдоподобными записями. Пустой или явно фальшивый сейф выдаёт себя. Значения придумайте сами — рекомендуем 3–5 записей.")
                    .font(.footnote).foregroundStyle(.secondary)
            }

            Section("Добавлено \(collected.count) из рекомендуемых 3–5") {
                if collected.isEmpty {
                    Text("Пока ничего не добавлено").foregroundStyle(.secondary)
                } else {
                    ForEach(collected) { ItemRow(item: $0) }
                        .onDelete { collected.remove(atOffsets: $0) }
                }
            }

            Section("Добавить запись") {
                Button("Почта") { editing = loginTemplate() }
                Button("Соцсеть") { editing = loginTemplate() }
                Button("Интернет-магазин") { editing = loginTemplate() }
                Button("Wi-Fi") { editing = noteTemplate() }
                Button("Заметка") { editing = noteTemplate() }
            }

            if let errorText {
                Text(errorText).foregroundStyle(.red).font(.footnote)
            }

            Section {
                Button("Готово") { finish() }.disabled(working)
                Button("Сделаю позже") { finish() }.foregroundStyle(.secondary).disabled(working)
            }
        }
        .navigationTitle("Наполните ложный сейф")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $editing) { item in
            NavigationStack {
                if case .secureNote = item.kind {
                    NoteEditorView(model: model, original: item, onCollect: { collected.append($0) })
                } else {
                    LoginEditorView(model: model, original: item, onCollect: { collected.append($0) })
                }
            }
        }
        .sheet(isPresented: Binding(get: { decoyRecoveryKey != nil }, set: { if !$0 { decoyRecoveryKey = nil } })) {
            RecoveryKeyView(
                key: decoyRecoveryKey ?? "",
                onSaved: { decoyRecoveryKey = nil; showSwitchOffer = true },
                onSkip: { decoyRecoveryKey = nil; showSwitchOffer = true }
            )
        }
        .alert("Готово", isPresented: $showSwitchOffer) {
            Button("Перейти в ложный сейф") { switchToDecoy() }
            Button("Позже", role: .cancel) { dismiss() }
        } message: {
            Text("Второй пароль включён. Перейти в ложный сейф сейчас?")
        }
    }

    private func loginTemplate() -> VaultItem {
        VaultItem(kind: .login(username: "", password: "", urls: [""], totpSecret: nil), title: "")
    }
    private func noteTemplate() -> VaultItem {
        VaultItem(kind: .secureNote, title: "")
    }

    private func finish() {
        working = true
        errorText = nil
        Task {
            defer { working = false }
            do {
                decoyRecoveryKey = try await model.enableSecondPassword(secondPassword, decoyItems: collected)
            } catch StashCore.VaultError.secondPasswordMustDiffer {
                errorText = String(localized: "Второй пароль должен отличаться от мастер-пароля.")
            } catch {
                errorText = String(localized: "Не удалось включить второй пароль.")
            }
        }
    }

    private func switchToDecoy() {
        Task {
            try? await model.openDecoy(second: secondPassword)
            dismiss()
        }
    }
}
