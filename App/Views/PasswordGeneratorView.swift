import SwiftUI
import StashCore

struct PasswordGeneratorView: View {
    let model: AppModel
    var onUse: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var options: PasswordGeneratorOptions
    @State private var generated: String = ""
    @State private var toast: Toast?

    init(model: AppModel, onUse: @escaping (String) -> Void) {
        self.model = model
        self.onUse = onUse
        _options = State(initialValue: model.generatorOptions)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(generated.isEmpty ? " " : generated)
                        .font(.title3.monospaced())
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .accessibilityLabel("Сгенерированный пароль")
                }

                Section("Длина: \(Int(options.length))") {
                    Slider(
                        value: Binding(
                            get: { Double(options.length) },
                            set: { options.length = Int($0); regenerate() }
                        ),
                        in: Double(PasswordGenerator.minLength)...Double(PasswordGenerator.maxLength),
                        step: 1
                    )
                    .accessibilityValue("\(options.length)")
                }

                Section("Символы") {
                    Toggle("Заглавные (A–Z)", isOn: binding(\.useUppercase))
                    Toggle("Строчные (a–z)", isOn: binding(\.useLowercase))
                    Toggle("Цифры (0–9)", isOn: binding(\.useDigits))
                    Toggle("Символы (!@#…)", isOn: binding(\.useSymbols))
                    Toggle("Исключить похожие (0/O, 1/l/I)", isOn: binding(\.excludeSimilar))
                }

                Section {
                    Button { regenerate() } label: {
                        Label("Сгенерировать заново", systemImage: "arrow.clockwise")
                    }
                    Button { copy() } label: {
                        Label("Копировать", systemImage: "doc.on.doc")
                    }
                    .disabled(generated.isEmpty)
                }
            }
            .navigationTitle("Генератор пароля")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Использовать") {
                        model.setGeneratorOptions(options)
                        onUse(generated)
                        dismiss()
                    }
                    .disabled(generated.isEmpty)
                }
            }
            .onAppear { if generated.isEmpty { regenerate() } }
            .toast($toast)
        }
    }

    private func binding(_ keyPath: WritableKeyPath<PasswordGeneratorOptions, Bool>) -> Binding<Bool> {
        Binding(
            get: { options[keyPath: keyPath] },
            set: { options[keyPath: keyPath] = $0; regenerate() }
        )
    }

    private func regenerate() {
        model.setGeneratorOptions(options)
        if let pw = try? PasswordGenerator.generate(options) {
            generated = pw
        } else {
            generated = ""
        }
    }

    private func copy() {
        guard !generated.isEmpty else { return }
        Clipboard.copy(generated)
        toast = Toast(text: "Скопировано. Очистится через 60 с")
    }
}
