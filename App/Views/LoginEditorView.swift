import SwiftUI
import PhotosUI
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

    @State private var totpSecret: String?
    @State private var showQRScanner = false
    @State private var showManualTOTP = false
    @State private var manualTOTP = ""
    @State private var totpPhoto: PhotosPickerItem?
    @State private var totpError: String?

    init(model: AppModel, original: VaultItem, onCollect: ((VaultItem) -> Void)? = nil) {
        self.model = model
        self.original = original
        self.onCollect = onCollect
        var u = "", p = "", t: String? = nil
        var list: [String] = []
        if case let .login(username, password, urls, totp) = original.kind {
            u = username; p = password; list = urls; t = totp
        }
        _totpSecret = State(initialValue: t)
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

            totpSection
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
        .fullScreenCover(isPresented: $showQRScanner, onDismiss: { model.endSystemScreen() }) {
            qrScannerSheet
        }
        .sheet(isPresented: $showManualTOTP) { manualTOTPSheet }
        .onChange(of: totpPhoto) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self),
                   let image = UIImage(data: data) {
                    let codes = await QRImageDecoder.decode(image)
                    if let first = codes.first(where: { OTPAuth.config(fromStored: $0) != nil })
                        ?? codes.first {
                        applyTOTP(first)
                    } else {
                        totpError = String(localized: "QR-код не найден на изображении.")
                    }
                }
                totpPhoto = nil
            }
        }
        .toast($toast)
    }

    // MARK: - Код 2FA

    @ViewBuilder
    private var totpSection: some View {
        Section("Код 2FA") {
            if let secret = totpSecret, let cfg = OTPAuth.config(fromStored: secret) {
                TOTPCodeView(config: cfg) { code, remaining in
                    Clipboard.copy(code, expiresIn: Double(max(10, remaining)))
                    toast = Toast(text: String(localized: "Код скопирован"))
                }
                if let label = [cfg.issuer, cfg.account].compactMap({ $0 }).first(where: { !$0.isEmpty }) {
                    Text(label).font(.footnote).foregroundStyle(.secondary)
                }
                Button("Удалить код 2FA", role: .destructive) { totpSecret = nil; totpError = nil }
                    .font(.footnote)
            } else {
                if QRScannerView.isSupported {
                    Button { startQRScan() } label: { Label("Сканировать QR", systemImage: "qrcode.viewfinder") }
                }
                PhotosPicker(selection: $totpPhoto, matching: .images) {
                    Label("Выбрать скриншот QR", systemImage: "photo")
                }
                Button { manualTOTP = ""; showManualTOTP = true } label: {
                    Label("Ввести вручную", systemImage: "keyboard")
                }
                if let totpError {
                    Text(totpError).font(.footnote).foregroundStyle(.red)
                }
            }
        }
    }

    @ViewBuilder
    private var qrScannerSheet: some View {
        if QRScannerView.isSupported {
            QRScannerView { result in
                showQRScanner = false
                applyTOTP(result)
            }
            .ignoresSafeArea()
            .overlay(alignment: .top) {
                Text("Наведите на QR-код 2FA")
                    .padding(8).background(.ultraThinMaterial, in: Capsule()).padding(.top, 60)
            }
            .overlay(alignment: .bottomTrailing) {
                Button("Отмена") { showQRScanner = false }
                    .padding().tint(.white)
            }
        }
    }

    @ViewBuilder
    private var manualTOTPSheet: some View {
        NavigationStack {
            Form {
                Section {
                    SecretTextField(text: $manualTOTP, placeholder: "Секрет или otpauth://…", secure: true)
                } footer: {
                    Text("Вставьте секрет Base32 или ссылку otpauth://totp/…")
                }
            }
            .navigationTitle("Код 2FA").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Отмена") { showManualTOTP = false } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") { applyTOTP(manualTOTP); showManualTOTP = false }
                        .disabled(manualTOTP.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private func startQRScan() {
        model.beginSystemScreen()
        showQRScanner = true
    }

    /// Разбирает отсканированное/введённое и сохраняет нормализованный otpauth-URL.
    private func applyTOTP(_ raw: String?) {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return }
        if raw.lowercased().hasPrefix("otpauth-migration://") {
            switch OTPAuth.parseMigration(raw) {
            case .success(let cfgs) where cfgs.count == 1:
                totpSecret = OTPAuth.makeURL(from: cfgs[0]); totpError = nil
            case .success(let cfgs) where cfgs.isEmpty:
                totpError = String(localized: "В экспорте нет кодов TOTP.")
            case .success:
                totpError = String(localized: "В экспорте несколько кодов — добавьте по одному.")
            case .failure:
                totpError = String(localized: "Не удалось разобрать экспорт.")
            }
            return
        }
        switch OTPAuth.parse(raw) {
        case .success(let cfg):
            totpSecret = OTPAuth.makeURL(from: cfg); totpError = nil
        case .failure(.hotpUnsupported):
            totpError = String(localized: "HOTP не поддерживается — нужен TOTP.")
        case .failure:
            totpError = String(localized: "Не удалось распознать код 2FA.")
        }
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
