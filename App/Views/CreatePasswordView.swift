import SwiftUI
import StashCore

struct CreatePasswordView: View {
    let model: AppModel

    @State private var password = ""
    @State private var confirm = ""
    @State private var reveal = false
    @State private var creating = false
    @State private var errorText: String?
    @State private var showWeakConfirm = false

    private var assessment: PasswordAssessment { PasswordEvaluator.assess(password) }
    private var passwordsMatch: Bool { password == confirm }
    private var canSubmit: Bool {
        password.count >= PasswordEvaluator.minimumLength && passwordsMatch && !creating
    }

    var body: some View {
        Form {
            Section("Мастер-пароль") {
                passwordField(placeholder: "Мастер-пароль", text: $password, isNew: true)
                passwordField(placeholder: "Повторите пароль", text: $confirm, isNew: true)
                Toggle("Показать пароль", isOn: $reveal)
            }

            Section {
                PasswordStrengthView(assessment: assessment)
                if !confirm.isEmpty && !passwordsMatch {
                    Label("Пароли не совпадают", systemImage: "xmark.circle")
                        .foregroundStyle(.red)
                        .font(.footnote)
                }
                if !password.isEmpty && password.count < PasswordEvaluator.minimumLength {
                    Text("Минимум \(PasswordEvaluator.minimumLength) символов")
                        .foregroundStyle(.secondary)
                        .font(.footnote)
                }
            }

            Section {
                Button(action: attemptCreate) {
                    Text("Создать сейф").frame(maxWidth: .infinity)
                }
                .disabled(!canSubmit)
            } footer: {
                Text("Мастер-пароль нельзя восстановить. Запомните его — без него данные не открыть.")
            }
        }
        .navigationTitle("Новый сейф")
        .navigationBarTitleDisplayMode(.inline)
        .disabled(creating)
        .overlay {
            if creating {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Создаём сейф…")
                }
                .padding(24)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            }
        }
        .alert("Слабый пароль", isPresented: $showWeakConfirm) {
            Button("Всё равно создать", role: .destructive) { create() }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Этот пароль легко подобрать. Лучше сделать его длиннее и разнообразнее.")
        }
        .alert("Не удалось создать сейф", isPresented: Binding(
            get: { errorText != nil }, set: { if !$0 { errorText = nil } }
        )) {
            Button("ОК", role: .cancel) { errorText = nil }
        } message: {
            Text(errorText ?? "")
        }
    }

    @ViewBuilder
    private func passwordField(placeholder: LocalizedStringResource, text: Binding<String>, isNew: Bool) -> some View {
        // Единая обёртка: без автокоррекции/предиктива/textContentType — iOS не предлагает
        // сохранить мастер-пароль в iCloud Keychain и не показывает подсказку сильного пароля.
        SecretTextField(text: text, placeholder: placeholder, secure: !reveal)
            .accessibilityLabel(Text(placeholder))
    }

    private func attemptCreate() {
        if assessment.isCommon || assessment.strength <= .weak {
            showWeakConfirm = true
        } else {
            create()
        }
    }

    private func create() {
        creating = true
        Task {
            do {
                try await model.createVault(masterPassword: password)
                // phase → .unlocked: RootView сам покажет главный экран.
            } catch {
                errorText = "Попробуйте ещё раз."
                creating = false
            }
        }
    }
}

struct PasswordStrengthView: View {
    let assessment: PasswordAssessment

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Надёжность")
                    .font(.footnote).foregroundStyle(.secondary)
                Spacer()
                Text(label).font(.footnote).bold().foregroundStyle(color)
            }
            // Даже «Очень слабый» показываем минимальной полоской (~10%), не пустой.
            ProgressView(value: max(0.1, Double(assessment.strength.rawValue) / 4.0))
                .tint(color)
            if assessment.isCommon {
                Text("Это один из самых распространённых паролей — его подбирают первым.")
                    .font(.caption).foregroundStyle(.red)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(String(localized: "Надёжность пароля: \(label)"))
    }

    private var label: String {
        switch assessment.strength {
        case .veryWeak: return String(localized: "Очень слабый")
        case .weak: return String(localized: "Слабый")
        case .fair: return String(localized: "Средний")
        case .strong: return String(localized: "Надёжный")
        case .veryStrong: return String(localized: "Очень надёжный")
        }
    }

    private var color: Color {
        switch assessment.strength {
        case .veryWeak, .weak: return .red
        case .fair: return .orange
        case .strong, .veryStrong: return .green
        }
    }
}
