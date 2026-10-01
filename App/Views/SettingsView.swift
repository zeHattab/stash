import SwiftUI
import StashCore

struct SettingsView: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss

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
                    if newValue {
                        try? await model.enableBiometrics()
                    } else {
                        model.disableBiometrics()
                    }
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
                    NavigationLink("Сменить мастер-пароль") {
                        ChangePasswordView(model: model)
                    }
                }

                Section("О приложении") {
                    LabeledContent("Версия", value: appVersion)
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
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Готово") { dismiss() }
                }
            }
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
                SecureField("Текущий мастер-пароль", text: $oldPassword)
                    .textContentType(.password)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            Section("Новый пароль") {
                SecureField("Новый мастер-пароль", text: $newPassword)
                    .textContentType(.newPassword)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("Повторите новый пароль", text: $confirm)
                    .textContentType(.newPassword)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                PasswordStrengthView(assessment: assessment)
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
            } catch {
                errorText = "Не удалось сменить пароль."
            }
        }
    }
}
