import SwiftUI
import UIKit
import Combine
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

            // В переключателе приложений и при .inactive прячем содержимое заглушкой —
            // но НЕ поверх системного экрана, который мы сами открыли (камера/пикер/шара).
            if scenePhase != .active && !model.presentingSystemScreen {
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
        .onReceive(NotificationCenter.default.publisher(
            for: UIApplication.protectedDataWillBecomeUnavailableNotification)) { _ in
            // iPhone заблокировали — закрываем сейф сразу, независимо от таймера.
            Task { await model.deviceDidLock() }
        }
        .onChange(of: model.items) { _, _ in
            // Планирует уведомления о сроках только открытый сейф.
            guard model.phase == .unlocked else { return }
            Task { await ExpiryNotifications.reschedule(items: model.items,
                                                        enabled: model.expiryRemindersEnabled,
                                                        tag: model.vaultTag) }
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
