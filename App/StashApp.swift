import SwiftUI
import UIKit
import StashCore

/// Запрещает сторонние клавиатуры во всём приложении: в редакторе секреты вводятся в
/// обычные текстовые поля, которые сторонние клавиатуры могли бы видеть.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     shouldAllowExtensionPointIdentifier extensionPointIdentifier: UIApplication.ExtensionPointIdentifier) -> Bool {
        extensionPointIdentifier != .keyboard
    }
}

@main
struct StashApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model: AppModel

    #if DEBUG
    private let isDemo = ProcessInfo.processInfo.arguments.contains("STASH_DEMO")
    #else
    private let isDemo = false
    #endif

    init() {
        let appGroup = "group.com.portie24.stash"
        #if DEBUG
        let demo = ProcessInfo.processInfo.arguments.contains("STASH_DEMO")
        #else
        let demo = false
        #endif
        // В демо-режиме — временный файл, чтобы не трогать реальный сейф.
        let vaultURL: URL = demo
            ? FileManager.default.temporaryDirectory.appendingPathComponent("stash-demo.stash")
            : (FileManager.default
                .containerURL(forSecurityApplicationGroupIdentifier: appGroup)?
                .appendingPathComponent("vault.stash")
               ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("vault.stash"))
        if demo { try? FileManager.default.removeItem(at: vaultURL) }

        let store = VaultStore(configuration: .init(fileURL: vaultURL, kdfIterations: demo ? 1_000 : 600_000))
        let model = AppModel(
            store: store,
            biometrics: SystemBiometricAuthenticator(),
            keychain: KeychainVaultKeyStore(),
            settings: UserDefaultsSettingsStore(suiteName: appGroup)
        )
        _model = State(initialValue: model)
    }

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
                .task {
                    #if DEBUG
                    if isDemo {
                        // Для скриншота онбординга сейф не создаём — показываем онбординг.
                        let onboarding = ProcessInfo.processInfo.arguments.contains("STASH_SCREEN=onboarding")
                        if onboarding { await model.start() }
                        else { await model.startDemo(items: DemoData.items()) }
                        return
                    }
                    #endif
                    await model.start()
                }
        }
    }
}
