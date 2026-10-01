import AuthenticationServices
import UIKit
import StashCore

/// Заглушка расширения AutoFill первого захода.
///
/// Показывает название «Stash» и кнопку «Отмена», которая закрывает запрос.
/// Реальная логика подбора учётных данных появится в следующих заходах.
final class CredentialProviderViewController: ASCredentialProviderViewController {

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        let title = UILabel()
        title.text = "Stash"
        title.font = .systemFont(ofSize: 34, weight: .bold)
        title.textAlignment = .center

        let cancelButton = UIButton(type: .system)
        cancelButton.setTitle(String(localized: "Отмена"), for: .normal)
        cancelButton.titleLabel?.font = .systemFont(ofSize: 17, weight: .semibold)
        cancelButton.addTarget(self, action: #selector(cancelTapped), for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [title, cancelButton])
        stack.axis = .vertical
        stack.spacing = 24
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
    }

    @objc private func cancelTapped() {
        extensionContext.cancelRequest(
            withError: NSError(
                domain: ASExtensionErrorDomain,
                code: ASExtensionError.userCanceled.rawValue
            )
        )
    }
}
