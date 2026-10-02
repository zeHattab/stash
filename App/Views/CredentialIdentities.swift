import Foundation
import AuthenticationServices
import StashCore

/// Регистрация идентичностей (домен + логин, БЕЗ пароля) в системном хранилище —
/// «подсказки над клавиатурой». Что именно регистрировать, решает StashCore
/// `CredentialIdentityPlan`: пусто при выключенной настройке / втором пароле / ложной сессии.
enum CredentialIdentities {

    @MainActor
    static func sync(model: AppModel) {
        let entries = CredentialIdentityPlan.entries(
            items: model.items,
            hintsEnabled: model.keyboardHintsEnabled,
            secondPasswordEnabled: model.secondPasswordEnabled,
            isDecoySession: model.isDecoySession)

        ASCredentialIdentityStore.shared.getState { state in
            guard state.isEnabled else { return } // расширение не включено в системе
            if entries.isEmpty {
                ASCredentialIdentityStore.shared.removeAllCredentialIdentities(completion: nil)
            } else {
                let identities: [ASCredentialIdentity] = entries.map { e in
                    ASPasswordCredentialIdentity(
                        serviceIdentifier: ASCredentialServiceIdentifier(identifier: e.domain, type: .domain),
                        user: e.user,
                        recordIdentifier: e.recordID)
                }
                ASCredentialIdentityStore.shared.replaceCredentialIdentities(with: identities, completion: nil)
            }
        }
    }

    /// Очистить всё хранилище идентичностей (при включении второго пароля).
    static func clearAll() {
        ASCredentialIdentityStore.shared.removeAllCredentialIdentities(completion: nil)
    }
}
