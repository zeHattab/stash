import AuthenticationServices
import UIKit
import CryptoKit
import StashCore

/// Что заполняем: пароль или одноразовый код.
enum CredentialProviderMode: Equatable { case password, oneTimeCode }

/// Расширение автозаполнения. Открывает тот же сейф (файл в App Group), разблокировка —
/// Face ID через общий Keychain (если второй пароль выключен и ключ есть) либо ввод пароля
/// (пароль открывает тот слот, который подошёл). После выдачи учётных данных ключ стирается.
final class CredentialProviderViewController: ASCredentialProviderViewController {

    private let store: VaultStore = {
        let appGroup = "group.com.portie24.stash"
        let url = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroup)?
            .appendingPathComponent("vault.stash")
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("vault.stash")
        return VaultStore(configuration: .init(fileURL: url, kdfIterations: 600_000))
    }()
    private let keychain = KeychainVaultKeyStore()

    private var serviceIdentifiers: [ASCredentialServiceIdentifier] = []
    private var mode: CredentialProviderMode = .password
    private var directRecordID: String?

    private var listController: LoginListController?

    // MARK: - Точки входа системы

    override func prepareCredentialList(for serviceIdentifiers: [ASCredentialServiceIdentifier]) {
        self.serviceIdentifiers = serviceIdentifiers
        self.mode = .password
        self.directRecordID = nil
        beginUnlock()
    }

    @available(iOS 18.0, *)
    override func prepareOneTimeCodeCredentialList(for serviceIdentifiers: [ASCredentialServiceIdentifier]) {
        self.serviceIdentifiers = serviceIdentifiers
        self.mode = .oneTimeCode
        self.directRecordID = nil
        beginUnlock()
    }

    // Без интерфейса сейф открыть нельзя — просим взаимодействие.
    override func provideCredentialWithoutUserInteraction(for credentialRequest: ASCredentialRequest) {
        extensionContext.cancelRequest(withError: NSError(
            domain: ASExtensionErrorDomain, code: ASExtensionError.userInteractionRequired.rawValue))
    }

    override func prepareInterfaceToProvideCredential(for credentialRequest: ASCredentialRequest) {
        self.directRecordID = credentialRequest.credentialIdentity.recordIdentifier
        if #available(iOS 18.0, *), credentialRequest is ASOneTimeCodeCredentialRequest {
            self.mode = .oneTimeCode
        } else {
            self.mode = .password
        }
        beginUnlock()
    }

    // MARK: - Разблокировка

    private func beginUnlock() {
        view.backgroundColor = .systemBackground
        Task { @MainActor in
            let exists = await store.exists()
            guard exists else { return showMessage(String(localized: "Сейф ещё не создан. Откройте приложение Stash.")) }
            if keychain.hasKey() {
                do {
                    if let data = try await keychain.load(reason: String(localized: "Разблокировать Stash")) {
                        let vk = SymmetricKey(data: data)
                        try await store.unlock(vaultKey: vk)
                        await proceedUnlocked()
                        return
                    }
                } catch {
                    // Пользователь отменил/не прошёл — предложим пароль.
                }
            }
            showPasswordEntry()
        }
    }

    private func proceedUnlocked() async {
        let logins = (try? await store.autofillLogins()) ?? []
        // Ключ больше не нужен в этом процессе — стираем из памяти сразу после выборки.
        if directRecordID != nil {
            await completeDirect(logins: logins)
            await store.lock()
            return
        }
        await MainActor.run { showList(logins) }
    }

    // MARK: - Экран ввода пароля

    private func showPasswordEntry() {
        clearChildren()
        let vc = PasswordEntryController { [weak self] password in
            guard let self else { return }
            Task { @MainActor in
                do {
                    try await self.store.unlock(masterPassword: password)
                    await self.proceedUnlocked()
                } catch {
                    self.presentedPasswordController?.showError()
                }
            }
        } onCancel: { [weak self] in
            self?.cancel()
        }
        embed(vc)
        presentedPasswordController = vc
    }
    private weak var presentedPasswordController: PasswordEntryController?

    // MARK: - Список логинов

    private func showList(_ logins: [AutoFillLogin]) {
        clearChildren()
        let requested = serviceIdentifiers.first?.identifier
        let list = LoginListController(
            logins: logins,
            serviceIdentifier: requested,
            mode: mode) { [weak self] chosen in
                self?.select(chosen)
            } onCancel: { [weak self] in
                self?.cancel()
            }
        listController = list
        embed(list)
    }

    private func select(_ login: AutoFillLogin) {
        Task { @MainActor in
            switch mode {
            case .password:
                let credential = ASPasswordCredential(user: login.username, password: login.password)
                await store.lock()
                extensionContext.completeRequest(withSelectedCredential: credential)
            case .oneTimeCode:
                if #available(iOS 18.0, *), let code = login.currentTOTPCode() {
                    let cred = ASOneTimeCodeCredential(code: code)
                    await store.lock()
                    extensionContext.completeOneTimeCodeRequest(using: cred)
                } else {
                    await store.lock()
                    cancel()
                }
            }
        }
    }

    private func completeDirect(logins: [AutoFillLogin]) async {
        guard let id = directRecordID, let login = logins.first(where: { $0.id.uuidString == id }) else {
            await MainActor.run { showList(logins) }
            return
        }
        await MainActor.run {
            switch mode {
            case .password:
                extensionContext.completeRequest(
                    withSelectedCredential: ASPasswordCredential(user: login.username, password: login.password))
            case .oneTimeCode:
                if #available(iOS 18.0, *), let code = login.currentTOTPCode() {
                    extensionContext.completeOneTimeCodeRequest(using: ASOneTimeCodeCredential(code: code))
                } else {
                    cancel()
                }
            }
        }
    }

    // MARK: - Вспомогательное

    private func cancel() {
        Task { await store.lock() }
        extensionContext.cancelRequest(withError: NSError(
            domain: ASExtensionErrorDomain, code: ASExtensionError.userCanceled.rawValue))
    }

    private func showMessage(_ text: String) {
        clearChildren()
        let label = UILabel()
        label.text = text
        label.numberOfLines = 0
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
            label.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -24),
        ])
    }

    private func embed(_ child: UIViewController) {
        addChild(child)
        child.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(child.view)
        NSLayoutConstraint.activate([
            child.view.topAnchor.constraint(equalTo: view.topAnchor),
            child.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            child.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            child.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        child.didMove(toParent: self)
    }

    private func clearChildren() {
        for child in children {
            child.willMove(toParent: nil)
            child.view.removeFromSuperview()
            child.removeFromParent()
        }
    }
}
