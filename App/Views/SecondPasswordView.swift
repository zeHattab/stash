import SwiftUI
import StashCore

struct SecondPasswordView: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var second = ""
    @State private var confirm = ""
    @State private var master = ""
    @State private var reveal = false
    @State private var working = false
    @State private var errorText: String?
    @State private var showSwitchOffer = false
    @State private var lastSecond = ""

    private var assessment: PasswordAssessment { PasswordEvaluator.assess(second) }
    private var canEnable: Bool {
        second.count >= PasswordEvaluator.minimumLength && second == confirm && !working
    }

    var body: some View {
        Form {
            Section {
                Text("Второй пароль открывает отдельный «ложный» сейф. Если вас заставляют разблокировать приложение, покажите его — настоящий сейф при этом не раскрывается.")
                Text("По файлам нельзя доказать, что второй сейф существует. Чтобы это работало, наполните ложный сейф правдоподобными записями.")
                    .font(.footnote).foregroundStyle(.secondary)
            }

            if model.secondPasswordEnabled {
                disableSection
            } else {
                enableSection
            }

            if let errorText {
                Text(errorText).foregroundStyle(.red).font(.footnote)
            }
        }
        .navigationTitle("Второй пароль")
        .navigationBarTitleDisplayMode(.inline)
        .disabled(working)
        .onChange(of: second) { _, _ in errorText = nil }
        .onChange(of: confirm) { _, _ in errorText = nil }
        .onChange(of: master) { _, _ in errorText = nil }
        .alert("Готово", isPresented: $showSwitchOffer) {
            Button("Перейти в ложный сейф") { switchToDecoy() }
            Button("Позже", role: .cancel) { dismiss() }
        } message: {
            Text("Ложный сейф создан и в нём уже есть примеры записей. Перейти и заполнить его?")
        }
    }

    @ViewBuilder
    private var enableSection: some View {
        Section("Новый второй пароль") {
            passwordField("Второй пароль", text: $second)
            passwordField("Повторите второй пароль", text: $confirm)
            Toggle("Показать пароль", isOn: $reveal)
            if !second.isEmpty { PasswordStrengthView(assessment: assessment) }
            if !confirm.isEmpty && second != confirm {
                Text("Пароли не совпадают").font(.footnote).foregroundStyle(.red)
            }
        }
        Section {
            Button(action: enable) {
                Text("Включить второй пароль").frame(maxWidth: .infinity)
            }
            .disabled(!canEnable)
        } footer: {
            Text("Второй пароль должен отличаться от мастер-пароля.")
        }
    }

    @ViewBuilder
    private var disableSection: some View {
        Section {
            passwordField("Мастер-пароль", text: $master)
            Button(role: .destructive, action: disable) {
                Text("Выключить второй пароль").frame(maxWidth: .infinity)
            }
            .disabled(master.isEmpty || working)
        } footer: {
            Text("Второй слот будет перезаписан случайными данными. Ложный сейф пропадёт.")
        }
    }

    @ViewBuilder
    private func passwordField(_ placeholder: LocalizedStringKey, text: Binding<String>) -> some View {
        Group {
            if reveal { TextField(placeholder, text: text) }
            else { SecureField(placeholder, text: text) }
        }
        .textContentType(.password)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
    }

    private func enable() {
        working = true
        errorText = nil
        let entered = second
        Task {
            defer { working = false }
            do {
                try await model.enableSecondPassword(entered)
                lastSecond = entered
                if model.isDecoySession {
                    dismiss()
                } else {
                    showSwitchOffer = true
                }
            } catch VaultError.secondPasswordMustDiffer {
                errorText = "Второй пароль должен отличаться от мастер-пароля."
            } catch {
                errorText = "Не удалось включить второй пароль."
            }
        }
    }

    private func disable() {
        working = true
        errorText = nil
        let entered = master
        Task {
            defer { working = false }
            do {
                try await model.disableSecondPassword(master: entered)
                dismiss()
            } catch VaultError.wrongPassword {
                errorText = "Мастер-пароль неверный."
                master = ""
            } catch {
                errorText = "Не удалось выключить второй пароль."
            }
        }
    }

    private func switchToDecoy() {
        Task {
            try? await model.openDecoy(second: lastSecond)
            dismiss()
        }
    }
}
