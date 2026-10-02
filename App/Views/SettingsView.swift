import SwiftUI
import AuthenticationServices
import StashCore

/// Признак тестовой сборки (DEBUG или TestFlight sandbox) — для скрытых отладочных экранов.
enum AppBuild {
    static var isDiagnosticsAvailable: Bool {
        #if DEBUG
        return true
        #else
        return Bundle.main.appStoreReceiptURL?.lastPathComponent == "sandboxReceipt"
        #endif
    }
}

struct SettingsView: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var showDiagnostics = false

    private var biometryName: String {
        switch model.biometryType {
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        case .none: return "Биометрия"
        }
    }

    private var autoLockBinding: Binding<AutoLockTimeout> {
        Binding(get: { model.autoLockTimeout }, set: { model.setAutoLockTimeout($0) })
    }

    private var biometricBinding: Binding<Bool> {
        Binding(
            get: { model.isBiometricEnabled },
            set: { newValue in
                Task {
                    if newValue { try? await model.enableBiometrics() }
                    else { model.disableBiometrics() }
                }
            }
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Безопасность") {
                    Toggle(biometryName, isOn: biometricBinding)
                        .disabled(!model.isBiometricAvailable)
                    if !model.isBiometricAvailable {
                        Text("Недоступно: настройте биометрию и код-пароль в настройках iPhone.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    Picker("Автоблокировка", selection: autoLockBinding) {
                        Text("Сразу").tag(AutoLockTimeout.immediately)
                        Text("Через 1 минуту").tag(AutoLockTimeout.oneMinute)
                        Text("Через 5 минут").tag(AutoLockTimeout.fiveMinutes)
                        Text("Через 15 минут").tag(AutoLockTimeout.fifteenMinutes)
                    }
                    Text("При блокировке iPhone сейф закрывается сразу.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Toggle("Напоминания о сроках", isOn: Binding(
                        get: { model.expiryRemindersEnabled },
                        set: { enabled in
                            model.setExpiryRemindersEnabled(enabled)
                            Task {
                                if enabled { await ExpiryNotifications.requestAuthorization() }
                                await ExpiryNotifications.reschedule(items: model.items, enabled: enabled, tag: model.vaultTag)
                            }
                        }
                    ))
                    NavigationLink {
                        SecondPasswordView(model: model)
                    } label: {
                        HStack {
                            Text("Второй пароль")
                            Spacer()
                            Text(model.secondPasswordEnabled ? "Вкл" : "Выкл")
                                .foregroundStyle(.secondary)
                        }
                    }
                    Picker("Напоминание о пароле", selection: Binding(
                        get: { model.masterReminderInterval },
                        set: { model.setMasterReminderInterval($0) }
                    )) {
                        Text("Каждые 7 дней").tag(ReminderInterval.days7)
                        Text("Каждые 14 дней").tag(ReminderInterval.days14)
                        Text("Каждые 30 дней").tag(ReminderInterval.days30)
                        Text("Никогда").tag(ReminderInterval.never)
                    }
                    NavigationLink {
                        RecoverySettingsView(model: model)
                    } label: {
                        HStack {
                            Text("Ключ восстановления")
                            Spacer()
                            if !model.recoveryKeySaved {
                                Text("Не сохранён").foregroundStyle(.orange)
                            }
                        }
                    }
                    NavigationLink("Сменить мастер-пароль") {
                        ChangePasswordView(model: model)
                    }
                }

                Section("Автозаполнение") {
                    if model.secondPasswordEnabled {
                        Toggle("Подсказки над клавиатурой", isOn: .constant(false)).disabled(true)
                        Text("Подсказки показывают сайты из сейфа на экране входа — с включённым вторым паролем они отключены.")
                            .font(.footnote).foregroundStyle(.secondary)
                    } else {
                        Toggle("Подсказки над клавиатурой", isOn: Binding(
                            get: { model.keyboardHintsEnabled },
                            set: { model.setKeyboardHintsEnabled($0) }))
                        Text("Показывают сайты и логины из сейфа над клавиатурой на экранах входа. Пароли в систему не передаются.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    NavigationLink("Как включить автозаполнение") { AutoFillHelpView() }
                }

                Section("О приложении") {
                    LabeledContent("Версия", value: appVersion)
                        .contentShape(Rectangle())
                        .onLongPressGesture(minimumDuration: 1.5) {
                            if AppBuild.isDiagnosticsAvailable { showDiagnostics = true }
                        }
                    LabeledContent("Лицензия", value: "GPLv3")
                    Link(destination: URL(string: "https://github.com/zeHattab/stash")!) {
                        Label("Исходный код на GitHub", systemImage: "chevron.left.forwardslash.chevron.right")
                    }
                    Text("Stash работает только на этом устройстве и не выходит в интернет. Ссылка выше откроется в Safari.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Настройки")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Готово") { dismiss() } }
            }
            .sheet(isPresented: $showDiagnostics) { ScanDiagnosticsView(model: model) }
        }
    }

    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }
}

struct ChangePasswordView: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var oldPassword = ""
    @State private var newPassword = ""
    @State private var confirm = ""
    @State private var reveal = false
    @State private var working = false
    @State private var errorText: String?

    private var assessment: PasswordAssessment { PasswordEvaluator.assess(newPassword) }
    private var canSubmit: Bool {
        !oldPassword.isEmpty
        && newPassword.count >= PasswordEvaluator.minimumLength
        && newPassword == confirm
        && !working
    }

    var body: some View {
        Form {
            Section("Текущий пароль") {
                field("Текущий пароль", text: $oldPassword)
            }
            Section("Новый пароль") {
                field("Новый пароль", text: $newPassword)
                field("Повторите новый пароль", text: $confirm)
                Toggle("Показать пароль", isOn: $reveal)
                if !newPassword.isEmpty {
                    PasswordStrengthView(assessment: assessment)
                }
                if !confirm.isEmpty && newPassword != confirm {
                    Text("Пароли не совпадают").font(.footnote).foregroundStyle(.red)
                }
            }
            if let errorText {
                Text(errorText).foregroundStyle(.red).font(.footnote)
            }
            Section {
                Button(action: submit) {
                    Text("Сменить пароль").frame(maxWidth: .infinity)
                }
                .disabled(!canSubmit)
            }
        }
        .navigationTitle("Смена пароля")
        .navigationBarTitleDisplayMode(.inline)
        .disabled(working)
        .onChange(of: oldPassword) { _, _ in errorText = nil }
        .onChange(of: newPassword) { _, _ in errorText = nil }
        .onChange(of: confirm) { _, _ in errorText = nil }
    }

    @ViewBuilder
    private func field(_ placeholder: String, text: Binding<String>) -> some View {
        SecretTextField(text: text, placeholder: placeholder, secure: !reveal)
    }

    private func submit() {
        working = true
        errorText = nil
        Task {
            defer { working = false }
            do {
                try await model.changeMasterPassword(old: oldPassword, new: newPassword)
                dismiss()
            } catch VaultError.wrongPassword {
                errorText = "Текущий пароль неверный."
                oldPassword = ""
            } catch {
                errorText = "Не удалось сменить пароль."
            }
        }
    }
}

struct RecoverySettingsView: View {
    let model: AppModel
    @State private var master = ""
    @State private var working = false
    @State private var errorText: String?
    @State private var newKey: String?

    var body: some View {
        Form {
            Section {
                if model.recoveryKeySaved {
                    Label("Ключ восстановления сохранён", systemImage: "checkmark.seal")
                        .foregroundStyle(.green)
                } else {
                    Label("Ключ восстановления не сохранён", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            }
            Section {
                SecretTextField(text: $master, placeholder: "Мастер-пароль", secure: true)
                Button("Создать новый ключ") { regenerate() }
                    .disabled(master.isEmpty || working)
            } footer: {
                Text("Старый ключ восстановления перестанет работать.")
            }
            if let errorText {
                Text(errorText).foregroundStyle(.red).font(.footnote)
            }
        }
        .navigationTitle("Ключ восстановления")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: Binding(get: { newKey != nil }, set: { if !$0 { newKey = nil } })) {
            RecoveryKeyView(
                key: newKey ?? "",
                onSaved: { Task { await model.markRecoveryKeySaved() }; newKey = nil },
                onSkip: { newKey = nil }
            )
        }
    }

    private func regenerate() {
        working = true; errorText = nil
        let entered = master
        Task {
            defer { working = false }
            do {
                newKey = try await model.regenerateRecoveryKey(master: entered)
                master = ""
            } catch VaultError.wrongPassword {
                errorText = "Мастер-пароль неверный."
            } catch {
                errorText = "Не удалось создать ключ."
            }
        }
    }
}

/// Как включить автозаполнение Stash в системе.
struct AutoFillHelpView: View {
    @State private var enabled: Bool?

    var body: some View {
        Form {
            Section {
                switch enabled {
                case .some(true):
                    Label("Stash включён в автозаполнении", systemImage: "checkmark.seal").foregroundStyle(.green)
                case .some(false):
                    Label("Stash пока не включён", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                case .none:
                    ProgressView()
                }
            }
            Section("Шаги") {
                Label("Откройте «Настройки» iPhone", systemImage: "1.circle")
                Label("Основные → Автозаполнение и пароли", systemImage: "2.circle")
                Label("Включите «Автозаполнение паролей»", systemImage: "3.circle")
                Label("Отметьте «Stash» в списке", systemImage: "4.circle")
            }
            Section {
                Button {
                    openAutoFillSettings()
                } label: {
                    Label("Открыть настройки", systemImage: "arrow.up.forward.app")
                }
            } footer: {
                Text("Stash работает только на этом устройстве и не выходит в интернет.")
            }
        }
        .navigationTitle("Автозаполнение")
        .navigationBarTitleDisplayMode(.inline)
        .task { refresh() }
    }

    private func refresh() {
        ASCredentialIdentityStore.shared.getState { state in
            let isEnabled = state.isEnabled
            Task { @MainActor in enabled = isEnabled }
        }
    }

    private func openAutoFillSettings() {
        // iOS 17+ открывает именно раздел автозаполнения; иначе — общие настройки приложения.
        Task { try? await ASSettingsHelper.openCredentialProviderAppSettings() }
    }
}

/// Скрытый экран отладки сканера. Показывает ТОЛЬКО технику последнего скана —
/// без распознанного текста и без данных документа.
struct ScanDiagnosticsView: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                if let d = model.lastScanDiagnostics {
                    Section("Последний скан") {
                        LabeledContent("Размер, px", value: "\(d.imageWidth)×\(d.imageHeight)")
                        LabeledContent("Ориентация", value: "\(d.orientationRaw)")
                        LabeledContent("Строк распознано", value: "\(d.recognizedLineCount)")
                        LabeledContent("Кандидатов MRZ", value: "\(d.mrzCandidateCount)")
                        LabeledContent("Склеек фрагментов", value: "\(d.joinCount)")
                        LabeledContent("Формат", value: d.detectedFormat ?? "—")
                        LabeledContent("Восстановлено", value: d.recovered ? "да" : "нет")
                        LabeledContent("Не сошлись", value: d.failedChecks.isEmpty ? "—" : d.failedChecks.joined(separator: ", "))
                    }
                    if !d.attempts.isEmpty {
                        Section("Попытки формата") {
                            ForEach(d.attempts, id: \.self) { Text($0).font(.footnote.monospaced()) }
                        }
                    }
                    Section {
                        Text("Только технические данные. Текст документа и его поля здесь не показываются и не сохраняются.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                } else {
                    Text("Сканов в этой сессии ещё не было.")
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Диагностика скана")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Готово") { dismiss() } }
            }
        }
    }
}
