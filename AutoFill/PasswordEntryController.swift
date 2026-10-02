import UIKit

/// Экран ввода мастер-пароля внутри расширения AutoFill.
final class PasswordEntryController: UIViewController {
    private let onSubmit: (String) -> Void
    private let onCancel: () -> Void
    private let field = UITextField()
    private let errorLabel = UILabel()

    init(onSubmit: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
        self.onSubmit = onSubmit
        self.onCancel = onCancel
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        title = "Stash"
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .cancel, target: self, action: #selector(cancelTapped))

        let prompt = UILabel()
        prompt.text = String(localized: "Введите мастер-пароль")
        prompt.font = .preferredFont(forTextStyle: .headline)
        prompt.adjustsFontForContentSizeCategory = true

        field.placeholder = String(localized: "Мастер-пароль")
        field.isSecureTextEntry = true
        field.autocorrectionType = .no
        field.spellCheckingType = .no
        field.smartQuotesType = .no
        field.smartDashesType = .no
        field.autocapitalizationType = .none
        field.textContentType = nil
        field.borderStyle = .roundedRect
        field.returnKeyType = .go
        field.delegate = self
        field.addTarget(self, action: #selector(editingChanged), for: .editingChanged)

        errorLabel.text = String(localized: "Неверный пароль")
        errorLabel.textColor = .systemRed
        errorLabel.font = .preferredFont(forTextStyle: .footnote)
        errorLabel.isHidden = true

        let button = UIButton(type: .system)
        button.setTitle(String(localized: "Разблокировать"), for: .normal)
        button.titleLabel?.font = .preferredFont(forTextStyle: .headline)
        button.addTarget(self, action: #selector(submit), for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [prompt, field, errorLabel, button])
        stack.axis = .vertical
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 32),
        ])
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        field.becomeFirstResponder()
    }

    func showError() {
        errorLabel.isHidden = false
        field.text = ""
        field.becomeFirstResponder()
    }

    @objc private func editingChanged() { errorLabel.isHidden = true }
    @objc private func submit() { onSubmit(field.text ?? "") }
    @objc private func cancelTapped() { onCancel() }
}

extension PasswordEntryController: UITextFieldDelegate {
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        submit()
        return true
    }
}
