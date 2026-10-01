import Foundation
import LocalAuthentication

/// Биометрия поверх LocalAuthentication. Структура без хранимого состояния (Sendable).
public struct SystemBiometricAuthenticator: BiometricAuthenticating {
    public init() {}

    public var biometryType: BiometryKind {
        let context = LAContext()
        var error: NSError?
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
        switch context.biometryType {
        case .faceID: return .faceID
        case .touchID: return .touchID
        default: return .none
        }
    }

    public var isAvailable: Bool {
        // true только если биометрия настроена И на устройстве есть код-пароль.
        let context = LAContext()
        var error: NSError?
        return context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
    }
}
