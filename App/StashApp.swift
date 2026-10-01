import SwiftUI

/// Точка входа приложения Stash.
///
/// Заход 1 — только каркас: бизнес-логики, хранилища и криптографии здесь нет,
/// корневой экран показывает заглушку.
@main
struct StashApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
