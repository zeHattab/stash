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
    @State private var showFill = false

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
                if model.decoyNeedsFilling && !model.isDecoySession {
                    Section {
                        Label("Ложный сейф почти пуст — наполните его", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                }
                if !model.isDecoySession {
                    Section {
                        NavigationLink("Сменить второй пароль") { ChangeSecondPasswordView(model: model) }
                    } footer: {
                        Text("Как наполнить ложный сейф: заблокируйте Stash и войдите вторым паролем.")
                    }
                }
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
        .navigationDestination(isPresented: $showFill) {
            DecoyFillView(model: model, secondPassword: second)
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
    private func passwordField(_ placeholder: LocalizedStringResource, text: Binding<String>) -> some View {
        SecretTextField(text: text, placeholder: placeholder, secure: !reveal)
    }

    private func enable() {
        if model.isDecoySession {
            // В ложном сейфе: сценарий проходит, но чужой слот не трогаем, экрана наполнения нет.
            working = true
            Task {
                defer { working = false }
                try? await model.enableSecondPassword(second)
                dismiss()
            }
            return
        }
        let entered = second
        working = true
        errorText = nil
        Task {
            defer { working = false }
            if await model.secondPasswordCollides(entered) {
                errorText = String(localized: "Второй пароль должен отличаться от мастер-пароля.")
            } else {
                showFill = true
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
                errorText = String(localized: "Мастер-пароль неверный.")
                master = ""
            } catch {
                errorText = String(localized: "Не удалось выключить второй пароль.")
            }
        }
    }
}

struct ChangeSecondPasswordView: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var master = ""
    @State private var newSecond = ""
    @State private var confirm = ""
    @State private var reveal = false
    @State private var working = false
    @State private var errorText: String?

    private var assessment: PasswordAssessment { PasswordEvaluator.assess(newSecond) }
    private var canSubmit: Bool {
        !master.isEmpty && newSecond.count >= PasswordEvaluator.minimumLength && newSecond == confirm && !working
    }

    var body: some View {
        Form {
            Section("Текущий мастер-пароль") {
                SecretTextField(text: $master, placeholder: "Мастер-пароль", secure: !reveal)
            }
            Section("Новый второй пароль") {
                SecretTextField(text: $newSecond, placeholder: "Новый второй пароль", secure: !reveal)
                SecretTextField(text: $confirm, placeholder: "Повторите второй пароль", secure: !reveal)
                Toggle("Показать пароль", isOn: $reveal)
                if !newSecond.isEmpty { PasswordStrengthView(assessment: assessment) }
            }
            if let errorText { Text(errorText).foregroundStyle(.red).font(.footnote) }
            Section {
                Button("Сменить второй пароль") { submit() }.disabled(!canSubmit)
            } footer: {
                Text("Содержимое ложного сейфа сохранится. Новый второй пароль должен отличаться от мастер-пароля.")
            }
        }
        .navigationTitle("Смена второго пароля")
        .navigationBarTitleDisplayMode(.inline)
        .disabled(working)
        .onChange(of: master) { _, _ in errorText = nil }
        .onChange(of: newSecond) { _, _ in errorText = nil }
        .onChange(of: confirm) { _, _ in errorText = nil }
    }

    private func submit() {
        working = true; errorText = nil
        let m = master, n = newSecond
        Task {
            defer { working = false }
            do {
                try await model.changeSecondPassword(master: m, newSecond: n)
                dismiss()
            } catch VaultError.wrongPassword {
                errorText = String(localized: "Мастер-пароль неверный.")
                master = ""
            } catch VaultError.secondPasswordMustDiffer {
                errorText = String(localized: "Новый второй пароль должен отличаться от мастер-пароля.")
            } catch {
                errorText = String(localized: "Не удалось сменить второй пароль.")
            }
        }
    }
}
