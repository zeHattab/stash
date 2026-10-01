import SwiftUI
import StashCore

struct LockView: View {
    let model: AppModel

    @State private var password = ""
    @State private var errorText: String?
    @State private var working = false
    @State private var didAutoPrompt = false

    var body: some View {
        VStack(spacing: 28) {
            Spacer()
            Image(systemName: "lock.shield")
                .font(.system(size: 64))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text("Stash")
                .font(.largeTitle).bold()

            VStack(spacing: 16) {
                SecureField("Мастер-пароль", text: $password)
                    .textContentType(.password)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Мастер-пароль")
                    .onSubmit { unlockWithPassword() }

                Button(action: unlockWithPassword) {
                    Text("Разблокировать").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(password.isEmpty || working)

                if model.isBiometricEnabled {
                    Button(action: unlockWithBiometrics) {
                        Label(biometricLabel, systemImage: biometricIcon)
                    }
                    .disabled(working)
                }
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
        .task {
            // Сразу предлагаем биометрию при появлении экрана блокировки.
            if model.isBiometricEnabled && !didAutoPrompt {
                didAutoPrompt = true
                unlockWithBiometrics()
            }
        }
    }

    private var biometricLabel: String {
        switch model.biometryType {
        case .faceID: return "Войти по Face ID"
        case .touchID: return "Войти по Touch ID"
        case .none: return "Войти по биометрии"
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
