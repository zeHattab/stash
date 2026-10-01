import SwiftUI
import StashCore

enum ItemFilter: String, CaseIterable, Identifiable {
    case all, logins, notes
    var id: String { rawValue }
    var title: LocalizedStringKey {
        switch self {
        case .all: return "Все"
        case .logins: return "Логины"
        case .notes: return "Заметки"
        }
    }
}

struct HomeView: View {
    let model: AppModel

    @State private var showSettings = false
    @State private var editing: VaultItem?
    @State private var pendingDelete: VaultItem?
    @State private var filter: ItemFilter = .all
    @State private var searchText = ""

    var body: some View {
        NavigationStack {
            Group {
                if model.items.isEmpty {
                    emptyState
                } else {
                    list
                }
            }
            .navigationTitle("Stash")
            .searchable(text: $searchText, prompt: "Поиск")
            .toolbar { toolbarContent }
            .sheet(isPresented: $showSettings) { SettingsView(model: model) }
            .sheet(item: $editing) { item in editor(for: item) }
            .sheet(isPresented: Binding(
                get: { model.pendingRecoveryKey != nil },
                set: { if !$0 { model.dismissRecoveryKey() } }
            )) {
                RecoveryKeyView(
                    key: model.pendingRecoveryKey ?? "",
                    onSaved: { Task { await model.markRecoveryKeySaved() } },
                    onSkip: { model.dismissRecoveryKey() }
                )
            }
            .sheet(isPresented: Binding(
                get: { model.pendingBiometricOffer && model.pendingRecoveryKey == nil },
                set: { if !$0 { model.dismissBiometricOffer() } }
            )) {
                BiometricOfferView(model: model)
            }
            .alert("Удалить запись?", isPresented: Binding(
                get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }
            )) {
                Button("Удалить", role: .destructive) {
                    if let item = pendingDelete { delete(item) }
                    pendingDelete = nil
                }
                Button("Отмена", role: .cancel) { pendingDelete = nil }
            } message: {
                Text("Запись «\(pendingDelete?.title ?? "")» будет удалена без возможности восстановить.")
            }
        }
    }

    // MARK: - Списки

    private var list: some View {
        List {
            if pool.isEmpty {
                Text("Ничего не найдено")
                    .foregroundStyle(.secondary)
            } else {
                section("Избранное", items: favorites)
                section("Логины", items: logins)
                section("Заметки", items: notes)
            }
        }
    }

    @ViewBuilder
    private func section(_ title: LocalizedStringKey, items: [VaultItem]) -> some View {
        if !items.isEmpty {
            Section(title) {
                ForEach(items) { item in
                    Button { editing = item } label: {
                        ItemRow(item: item).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) { pendingDelete = item } label: {
                            Label("Удалить", systemImage: "trash")
                        }
                    }
                    .swipeActions(edge: .leading) {
                        Button { toggleFavorite(item) } label: {
                            Label(item.favorite ? "Убрать" : "В избранное",
                                  systemImage: item.favorite ? "star.slash" : "star")
                        }
                        .tint(.yellow)
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "tray")
                .font(.system(size: 56)).foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("Сейф пуст").font(.title3).bold()
            Text("Скоро здесь будут пароли и документы.")
                .foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button("Добавить первый пароль") { addLogin() }
                .buttonStyle(.borderedProminent)
        }
        .padding()
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button("Заблокировать") { Task { await model.lock() } }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Picker("Фильтр", selection: $filter) {
                    ForEach(ItemFilter.allCases) { Text($0.title).tag($0) }
                }
                Picker("Сортировка", selection: Binding(
                    get: { model.sortOrder }, set: { model.setSortOrder($0) }
                )) {
                    Text("По названию").tag(VaultSortOrder.title)
                    Text("По дате изменения").tag(VaultSortOrder.dateModified)
                }
            } label: {
                Image(systemName: "line.3.horizontal.decrease.circle")
            }
            .accessibilityLabel("Фильтр и сортировка")
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button { addLogin() } label: { Label("Логин", systemImage: "key") }
                Button { addNote() } label: { Label("Заметка", systemImage: "note.text") }
            } label: {
                Image(systemName: "plus")
            }
            .accessibilityLabel("Добавить")
        }
        // Настройки — ОТДЕЛЬНАЯ, явная и одинаковая кнопка в обоих сейфах (без привязки к типу сессии).
        ToolbarItem(placement: .topBarTrailing) {
            Button { showSettings = true } label: { Image(systemName: "gearshape") }
                .accessibilityLabel("Настройки")
        }
    }

    // MARK: - Производные списки

    private var pool: [VaultItem] {
        var list = model.items
        switch filter {
        case .all: break
        case .logins: list = list.filter { isLogin($0) }
        case .notes: list = list.filter { isNote($0) }
        }
        list = VaultSearch.filter(list, query: searchText)
        return sorted(list)
    }

    private var favorites: [VaultItem] { pool.filter(\.favorite) }
    private var logins: [VaultItem] { pool.filter { isLogin($0) && !$0.favorite } }
    private var notes: [VaultItem] { pool.filter { isNote($0) && !$0.favorite } }

    private func sorted(_ items: [VaultItem]) -> [VaultItem] {
        switch model.sortOrder {
        case .title:
            return items.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case .dateModified:
            return items.sorted { $0.updatedAt > $1.updatedAt }
        }
    }

    private func isLogin(_ item: VaultItem) -> Bool {
        if case .login = item.kind { return true }; return false
    }
    private func isNote(_ item: VaultItem) -> Bool {
        if case .secureNote = item.kind { return true }; return false
    }

    // MARK: - Действия

    private func addLogin() {
        editing = VaultItem(kind: .login(username: "", password: "", urls: [], totpSecret: nil), title: "")
    }
    private func addNote() {
        editing = VaultItem(kind: .secureNote, title: "")
    }

    private func delete(_ item: VaultItem) {
        Task { try? await model.delete(item.id) }
    }
    private func toggleFavorite(_ item: VaultItem) {
        Task { try? await model.toggleFavorite(item.id) }
    }

    @ViewBuilder
    private func editor(for item: VaultItem) -> some View {
        NavigationStack {
            if case .secureNote = item.kind {
                NoteEditorView(model: model, original: item)
            } else {
                LoginEditorView(model: model, original: item)
            }
        }
    }
}

struct BiometricOfferView: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var working = false

    private var typeName: String {
        switch model.biometryType {
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        case .none: return "биометрию"
        }
    }

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: model.biometryType == .touchID ? "touchid" : "faceid")
                .font(.system(size: 64)).foregroundStyle(.tint)
                .accessibilityHidden(true)

            if model.isBiometricAvailable {
                Text("Входить по \(typeName)?")
                    .font(.title2).bold().multilineTextAlignment(.center)
                Text("Так сейф можно открывать быстро. Мастер-пароль всё равно понадобится после перезапуска и при изменении биометрии.")
                    .foregroundStyle(.secondary).multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                Spacer()
                Button { enable() } label: {
                    Text("Включить \(typeName)").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .disabled(working).padding(.horizontal, 32)
                Button("Не сейчас") { dismiss() }.padding(.bottom)
            } else {
                Text("Биометрия недоступна")
                    .font(.title2).bold().multilineTextAlignment(.center)
                Text("Чтобы входить по Face ID или Touch ID, настройте их и код-пароль в настройках iPhone. Пока вход только по мастер-паролю.")
                    .foregroundStyle(.secondary).multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                Spacer()
                Button { dismiss() } label: {
                    Text("Продолжить").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .padding([.horizontal, .bottom], 32)
            }
        }
        .padding(.top, 40)
        .interactiveDismissDisabled(working)
    }

    private func enable() {
        working = true
        Task {
            defer { working = false }
            try? await model.enableBiometrics()
            dismiss()
        }
    }
}
