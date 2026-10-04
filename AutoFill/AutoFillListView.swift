import SwiftUI
import StashCore

/// Что заполняем: пароль или одноразовый код. Общий тип для расширения и демо в приложении.
enum CredentialProviderMode: Equatable { case password, oneTimeCode }

/// Корневой экран расширения автозаполнения (и демо STASH_SCREEN=autofill).
/// NavigationStack с заголовком, Отменой, поиском, видимой кнопкой генератора и секциями
/// «Для <домен>» / «Другие записи». Выбор записи чужого домена требует подтверждения.
struct AutoFillListView: View {
    let logins: [AutoFillLogin]
    let requestHost: String?
    let mode: CredentialProviderMode
    var onSelect: (AutoFillLogin) -> Void
    var onCancel: () -> Void
    var onGenerate: (() -> Void)?

    @State private var search = ""
    @State private var crossDomain: AutoFillLogin?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if let host = requestHost {
                        Text(String(format: NSLocalizedString("для %@", comment: ""), host))
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    if mode == .password, let onGenerate {
                        Button { onGenerate() } label: {
                            Label(generateTitle, systemImage: "dice")
                        }
                    }
                }

                if requestHost != nil {
                    Section(matchHeader) {
                        if matching.isEmpty {
                            Text(emptyMatchText).foregroundStyle(.secondary)
                        } else {
                            ForEach(matching) { row($0, crossDomain: false) }
                        }
                    }
                    if !others.isEmpty {
                        Section(NSLocalizedString("Другие записи", comment: "")) {
                            ForEach(others) { row($0, crossDomain: true) }
                        }
                    }
                } else {
                    Section(NSLocalizedString("Все записи", comment: "")) {
                        if filtered.isEmpty {
                            Text(NSLocalizedString("Нет сохранённых паролей", comment: "")).foregroundStyle(.secondary)
                        }
                        ForEach(filtered) { row($0, crossDomain: false) }
                    }
                }
            }
            .navigationTitle("Stash")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $search, prompt: Text(NSLocalizedString("Поиск", comment: "")))
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button(NSLocalizedString("Отмена", comment: "")) { onCancel() } }
            }
            .alert(NSLocalizedString("Подставить пароль?", comment: ""),
                   isPresented: Binding(get: { crossDomain != nil }, set: { if !$0 { crossDomain = nil } }),
                   presenting: crossDomain) { login in
                Button(NSLocalizedString("Подставить", comment: "")) { onSelect(login) }
                Button(NSLocalizedString("Отмена", comment: ""), role: .cancel) {}
            } message: { login in
                Text(String(format: NSLocalizedString("Подставить пароль от %@ на %@?", comment: ""),
                            loginHost(login) ?? login.title, requestHost ?? ""))
            }
        }
    }

    @ViewBuilder
    private func row(_ login: AutoFillLogin, crossDomain requiresConfirm: Bool) -> some View {
        Button {
            if requiresConfirm, mode == .password { crossDomain = login } else { onSelect(login) }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(login.title.isEmpty ? login.username : login.title).foregroundStyle(.primary)
                HStack(spacing: 8) {
                    if !login.username.isEmpty {
                        Text(login.username).font(.footnote).foregroundStyle(.secondary)
                    }
                    if let host = loginHost(login) {
                        Text(host).font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Производные списки

    private var usable: [AutoFillLogin] {
        mode == .oneTimeCode ? logins.filter { $0.totpSecret != nil } : logins
    }
    private var filtered: [AutoFillLogin] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return usable }
        return usable.filter { l in
            l.title.lowercased().contains(q) || l.username.lowercased().contains(q)
                || l.urls.contains { $0.lowercased().contains(q) }
        }
    }
    private var matching: [AutoFillLogin] {
        guard let h = requestHost else { return [] }
        return filtered.filter { $0.matches(serviceIdentifier: h) }
    }
    private var others: [AutoFillLogin] {
        let ids = Set(matching.map(\.id))
        return filtered.filter { !ids.contains($0.id) }
    }

    private func loginHost(_ login: AutoFillLogin) -> String? {
        for url in login.urls { if let h = DomainMatch.host(from: url) { return h } }
        return nil
    }

    private var matchHeader: String {
        String(format: NSLocalizedString("Для %@", comment: ""), requestHost ?? "")
    }
    private var emptyMatchText: String {
        String(format: NSLocalizedString("Для %@ сохранённых паролей нет", comment: ""), requestHost ?? "")
    }
    private var generateTitle: String {
        if let host = requestHost {
            return String(format: NSLocalizedString("Сгенерировать новый пароль для %@", comment: ""), host)
        }
        return NSLocalizedString("Сгенерировать новый пароль", comment: "")
    }
}
