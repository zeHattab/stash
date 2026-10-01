import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Копирование в буфер: только локально (не в «Универсальный буфер» на другие
/// устройства) и с автоочисткой через 60 секунд.
enum Clipboard {
    @MainActor
    static func copy(_ string: String, expiresIn seconds: TimeInterval = 60) {
        UIPasteboard.general.setItems(
            [[UTType.utf8PlainText.identifier: string]],
            options: [
                .localOnly: true,
                .expirationDate: Date().addingTimeInterval(seconds),
            ]
        )
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }
}

/// Короткое всплывающее уведомление снизу.
struct Toast: Equatable, Identifiable {
    let id = UUID()
    let text: String
}

private struct ToastModifier: ViewModifier {
    @Binding var toast: Toast?

    func body(content: Content) -> some View {
        content.overlay(alignment: .bottom) {
            if let toast {
                Text(toast.text)
                    .font(.footnote)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.bottom, 24)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .accessibilityAddTraits(.updatesFrequently)
                    .task(id: toast.id) {
                        try? await Task.sleep(nanoseconds: 2_200_000_000)
                        withAnimation { self.toast = nil }
                    }
            }
        }
        .animation(.spring(duration: 0.3), value: toast)
    }
}

extension View {
    func toast(_ toast: Binding<Toast?>) -> some View {
        modifier(ToastModifier(toast: toast))
    }
}
