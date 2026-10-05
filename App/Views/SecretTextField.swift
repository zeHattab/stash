import SwiftUI
import UIKit

/// Единая обёртка для всех полей с секретами (пароли, второй пароль, ключ восстановления).
/// Отключает автокоррекцию, проверку орфографии, умную пунктуацию и предиктивный ввод,
/// не задаёт textContentType (чтобы iOS не предлагала сохранить пароль и сильные пароли).
/// Сторонние клавиатуры запрещены на уровне приложения (см. AppDelegate).
struct SecretTextField: UIViewRepresentable {
    @Binding var text: String
    /// Локализуемый placeholder: литерал-ключ извлекается в каталог, значение берём
    /// через String(localized:) (иначе Text(String)/UITextField.placeholder не переводятся).
    var placeholder: LocalizedStringResource? = nil
    /// true — маскировать точками (secureTextEntry).
    var secure: Bool = true
    /// Для ключа восстановления: заглавные + ASCII-клавиатура.
    var uppercase: Bool = false
    var bordered: Bool = false
    var onSubmit: (() -> Void)? = nil

    func makeUIView(context: Context) -> UITextField {
        let field = UITextField()
        field.delegate = context.coordinator
        field.autocorrectionType = .no
        field.spellCheckingType = .no
        field.smartQuotesType = .no
        field.smartDashesType = .no
        field.smartInsertDeleteType = .no
        field.textContentType = nil
        field.returnKeyType = .done
        field.addTarget(context.coordinator, action: #selector(Coordinator.editingChanged(_:)), for: .editingChanged)
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateUIView(_ field: UITextField, context: Context) {
        context.coordinator.text = $text
        context.coordinator.onSubmit = onSubmit
        if field.text != text { field.text = text }
        field.placeholder = placeholder.map { String(localized: $0) }
        field.isSecureTextEntry = secure
        field.autocapitalizationType = uppercase ? .allCharacters : .none
        field.keyboardType = uppercase ? .asciiCapable : .default
        field.borderStyle = bordered ? .roundedRect : .none
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text, onSubmit: onSubmit) }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var text: Binding<String>
        var onSubmit: (() -> Void)?
        init(text: Binding<String>, onSubmit: (() -> Void)?) {
            self.text = text; self.onSubmit = onSubmit
        }
        @objc func editingChanged(_ field: UITextField) { text.wrappedValue = field.text ?? "" }
        func textFieldShouldReturn(_ field: UITextField) -> Bool {
            onSubmit?(); field.resignFirstResponder(); return true
        }
    }
}
