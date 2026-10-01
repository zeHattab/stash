import SwiftUI
import StashCore

struct LockView: View {
    let model: AppModel

    @State private var password = ""
    @State private var errorText: String?
    @State private var working = false
    @State private var didAutoPrompt = false
    @State private var showForgot = false

    private var checkDue: Bool { model.isMasterCheckDue() }

    var body: some View {
        VStack(spacing: 28) {
            Spacer()
            Image(systemName: "lock.shield")
                .font(.system(size: 64))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text("Stash")
                .font(.largeTitle).bold()

            if checkDue {
                Text("Проверим, что вы помните пароль — введите мастер-пароль.")
                    .font(.footnote).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).padding(.horizontal, 32)
            }

            VStack(spacing: 16) {
                SecretTextField(text: $password, placeholder: "Мастер-пароль", secure: true,
                                bordered: true, onSubmit: { unlockWithPassword() })
                    .frame(height: 36)
                    .accessibilityLabel("Мастер-пароль")

                Button(action: unlockWithPassword) {
                    Text("Разблокировать").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(password.isEmpty || working)

                if model.isBiometricEnabled && !checkDue {
                    Button(action: unlockWithBiometrics) {
                        Label(biometricLabel, systemImage: biometricIcon)
                    }
                    .disabled(working)
                }

                Button("Забыли пароль?") { showForgot = true }
                    .font(.footnote)
            }
            .padding(.horizontal, 32)

            if let errorText {
                Text(errorText)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
            Spacer()
        }
        .sheet(isPresented: $showForgot) { ForgotPasswordView(model: model) }
        .task {
            // Автозапрос Face ID — только при возврате из фона / блокировке устройства /
            // холодном старте. После РУЧНОЙ блокировки и когда пора проверить пароль — нет.
            if model.isBiometricEnabled, model.lockReason != .manual, !checkDue, !didAutoPrompt {
                didAutoPrompt = true
                unlockWithBiometrics()
            }
        }
    }

    private var biometricLabel: String {
        switch model.biometryType {
        case .faceID: return "Открыть с Face ID"
        case .touchID: return "Открыть с Touch ID"
        case .none: return "Открыть с биометрией"
        }
    }

    private var biometricIcon: String {
        model.biometryType == .touchID ? "touchid" : "faceid"
    }

    private func unlockWithPassword() {
        guard !password.isEmpty else { return }
        working = true
        errorText = nil
        Task {
            defer { working = false }
            do {
                try await model.unlockWithPassword(password)
                password = ""
            } catch let AppModelError.lockedOut(remaining) {
                let minutes = Int(ceil(remaining / 60))
                errorText = minutes <= 1
                    ? "Слишком много попыток. Повторите примерно через минуту."
                    : "Слишком много попыток. Повторите примерно через \(minutes) мин."
            } catch {
                errorText = "Неверный пароль."
            }
        }
    }

    private func unlockWithBiometrics() {
        working = true
        Task {
            defer { working = false }
            do {
                try await model.unlockWithBiometrics()
            } catch {
                // Отмена/ошибка биометрии — молча остаёмся на экране, пароль доступен.
            }
        }
    }
}
