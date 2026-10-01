import SwiftUI
import StashCore

struct RootView: View {
    let model: AppModel
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            switch model.phase {
            case .onboarding: OnboardingView(model: model)
            case .locked: LockView(model: model)
            case .unlocked: HomeView(model: model)
            }

            // В переключателе приложений и при .inactive прячем содержимое заглушкой.
            if scenePhase != .active {
                PrivacyShade()
            }
        }
        .animation(.default, value: model.phase)
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .background:
                Task { await model.didEnterBackground(at: Date()) }
            case .active:
                Task { await model.willEnterForeground(at: Date()) }
            default:
                break
            }
        }
    }
}

/// Заглушка, закрывающая данные на скриншоте многозадачности.
struct PrivacyShade: View {
    var body: some View {
        ZStack {
            Color(uiColor: .systemBackground).ignoresSafeArea()
            Image(systemName: "lock.shield")
                .font(.system(size: 64))
                .foregroundStyle(.secondary)
        }
        .accessibilityHidden(true)
    }
}
