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

    init() {
        let appGroup = "group.com.portie24.stash"
        let vaultURL = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroup)?
            .appendingPathComponent("vault.stash")
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("vault.stash")

        let store = VaultStore(configuration: .init(fileURL: vaultURL, kdfIterations: 600_000))
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
                .task { await model.start() }
        }
    }
}
