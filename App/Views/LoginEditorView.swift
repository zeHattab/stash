import SwiftUI
import StashCore

struct LoginEditorView: View {
    let model: AppModel
    let original: VaultItem
    /// Если задано — запись не сохраняется в сейф, а возвращается через колбэк
    /// (используется на экране наполнения ложного сейфа).
    var onCollect: ((VaultItem) -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    @State private var title: String
    @State private var username: String
    @State private var password: String
    @State private var urls: [String]
    @State private var notes: String
    @State private var favorite: Bool
    @State private var reveal = false
    @State private var showGenerator = false
    @State private var revealHistory = false
    @State private var confirmDelete = false
    @State private var toast: Toast?

    private let totpSecret: String?

    init(model: AppModel, original: VaultItem, onCollect: ((VaultItem) -> Void)? = nil) {
        self.model = model
        self.original = original
        self.onCollect = onCollect
        var u = "", p = "", t: String? = nil
        var list: [String] = []
        if case let .login(username, password, urls, totp) = original.kind {
            u = username; p = password; list = urls; t = totp
        }
        self.totpSecret = t
        _title = State(initialValue: original.title)
        _username = State(initialValue: u)
        _password = State(initialValue: p)
        _urls = State(initialValue: list.isEmpty ? [""] : list)
        _notes = State(initialValue: original.notes)
        _favorite = State(initialValue: original.favorite)
        _reveal = State(initialValue: p.isEmpty) // у новой записи поле сразу редактируемо
    }

    private var isExisting: Bool { model.items.contains { $0.id == original.id } }
    private var assessment: PasswordAssessment { PasswordEvaluator.assess(password) }

    private var reuseCount: Int {
        guard !password.isEmpty else { return 0 }
        return model.items.reduce(0) { count, item in
            guard item.id != original.id,
                  case let .login(_, p, _, _) = item.kind, p == password else { return count }
            return count + 1
        }
    }

    var body: some View {
        Form {
            Section {
                TextField("Название", text: $title)
                    .textInputAutocapitalization(.sentences)
                Toggle("Избранное", isOn: $favorite)
            }

            Section("Логин") {
                // Без textContentType(.username): не даём iOS принять экран за форму входа.
                TextField("Логин или e-mail", text: $username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }

            Section("Пароль") {
                HStack {
                    // Не SecureField и без textContentType — iOS не предлагает «Сохранить пароль?».
                    // Скрытый непустой пароль показываем фиксированными точками (не выдаёт длину).
                    if reveal {
                        TextField("Пароль", text: $password)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    } else if password.isEmpty {
                        Text("Пароль").foregroundStyle(.secondary)
                    } else {
                        Text("••••••••").foregroundStyle(.primary)
                    }
                    Spacer()
                    Button {
                        reveal.toggle()
                    } label: {
                        Image(systemName: reveal ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(reveal ? "Скрыть пароль" : "Показать пароль")
                }
                if !password.isEmpty {
                    PasswordStrengthView(assessment: assessment)
                }
                HStack {
                    Button { copy(password) } label: { Label("Копировать", systemImage: "doc.on.doc") }
                        .disabled(password.isEmpty)
                    Spacer()
                    Button { showGenerator = true } label: { Label("Сгенерировать", systemImage: "dice") }
                }
                .buttonStyle(.borderless)
                .font(.footnote)

                if assessment.strength <= .weak && !password.isEmpty {
                    Label("Слабый пароль", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange).font(.footnote)
                }
                if reuseCount > 0 {
                    Label("Этот пароль используется ещё в \(reuseCount) записях",
                          systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange).font(.footnote)
                }
            }

            urlsSection
            historySection

            Section("Заметка") {
                TextField("Заметка", text: $notes, axis: .vertical)
                    .lineLimit(1...6)
            }

            if isExisting {
                Section {
                    Button("Удалить запись", role: .destructive) { confirmDelete = true }
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .navigationTitle(isExisting ? "Логин" : "Новый логин")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Готово") { save() }.disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .sheet(isPresented: $showGenerator) {
            PasswordGeneratorView(model: model) { generated in
                password = generated
                reveal = true
            }
        }
        .alert("Удалить запись?", isPresented: $confirmDelete) {
            Button("Удалить", role: .destructive) {
                Task { try? await model.delete(original.id); dismiss() }
            }
            Button("Отмена", role: .cancel) {}
        }
        .toast($toast)
    }

    @ViewBuilder
    private var urlsSection: some View {
        Section("Адреса сайтов") {
            ForEach(urls.indices, id: \.self) { index in
                HStack {
                    TextField("", text: $urls[index], prompt: Text("Адрес сайта"))
                        .foregroundStyle(urls[index].isEmpty ? Color.primary : Color.accentColor)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    if let url = normalizedURL(urls[index]) {
                        Button { openURL(url) } label: { Image(systemName: "safari") }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Открыть сайт")
                    }
                }
            }
            .onDelete { offsets in urls.remove(atOffsets: offsets) }
            Button { urls.append("") } label: { Label("Добавить адрес", systemImage: "plus") }
                .font(.footnote)
        }
    }

    @ViewBuilder
    private var historySection: some View {
        if let history = original.passwordHistory, !history.isEmpty {
            Section("Прошлые пароли") {
                Toggle("Показать прошлые пароли", isOn: $revealHistory)
                if revealHistory {
                    ForEach(history) { entry in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(entry.password).font(.body.monospaced()).lineLimit(1)
                                Text(entry.changedAt, style: .date)
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button { copy(entry.password) } label: { Image(systemName: "doc.on.doc") }
                                .buttonStyle(.borderless)
                                .accessibilityLabel("Копировать прошлый пароль")
                        }
                    }
                }
            }
        }
    }

    private func normalizedURL(_ string: String) -> URL? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let withScheme = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        return URL(string: withScheme)
    }

    private func copy(_ value: String) {
        Clipboard.copy(value)
        toast = Toast(text: "Скопировано. Очистится через 60 с")
    }

    private func save() {
        let cleaned = urls.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        var item = original
        item.title = title.trimmingCharacters(in: .whitespaces)
        item.notes = notes
        item.favorite = favorite
        item.kind = .login(username: username, password: password, urls: cleaned, totpSecret: totpSecret)
        if let onCollect {
            onCollect(item)
            dismiss()
        } else {
            Task { try? await model.save(item); dismiss() }
        }
    }
}
