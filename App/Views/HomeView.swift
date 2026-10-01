import SwiftUI
import StashCore

struct HomeView: View {
    let model: AppModel
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Spacer()
                Image(systemName: "tray")
                    .font(.system(size: 56))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text("Сейф пуст")
                    .font(.title3).bold()
                Text("Скоро здесь будут пароли и документы.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Spacer()
            }
            .padding()
            .navigationTitle("Stash")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Заблокировать") {
                        Task { await model.lock() }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Настройки")
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView(model: model)
            }
            .sheet(isPresented: Binding(
                get: { model.pendingBiometricOffer },
                set: { if !$0 { model.dismissBiometricOffer() } }
            )) {
                BiometricOfferView(model: model)
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
                .font(.system(size: 64))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)

            if model.isBiometricAvailable {
                Text("Входить по \(typeName)?")
                    .font(.title2).bold().multilineTextAlignment(.center)
                Text("Так сейф можно открывать быстро. Мастер-пароль всё равно понадобится после перезапуска и при изменении биометрии.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                Spacer()
                Button {
                    enable()
                } label: {
                    Text("Включить \(typeName)").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(working)
                .padding(.horizontal, 32)
                Button("Не сейчас") { dismiss() }
                    .padding(.bottom)
            } else {
                Text("Биометрия недоступна")
                    .font(.title2).bold().multilineTextAlignment(.center)
                Text("Чтобы входить по Face ID или Touch ID, настройте их и код-пароль в настройках iPhone. Пока вход только по мастер-паролю.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Text("Продолжить").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
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
            do {
                try await model.enableBiometrics()
                dismiss()
            } catch {
                dismiss()
            }
        }
    }
}
