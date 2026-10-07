import SwiftUI
import UIKit
import StashCore

/// Показ ключа восстановления: копирование, сохранение в PDF (локально, через системный
/// лист «Поделиться»), подтверждение «Я сохранил ключ» вводом двух случайных групп.
struct RecoveryKeyView: View {
    let key: String
    var allowSkip: Bool = true
    var onSaved: () -> Void
    var onSkip: () -> Void

    private enum Step { case show, confirm }
    @State private var step: Step = .show
    @State private var askIndices: [Int] = [0, 1]
    @State private var answers: [String] = ["", ""]
    @State private var pdfURL: URL?
    @State private var toast: Toast?
    @State private var confirmError = false

    private var groups: [String] { key.split(separator: "-").map(String.init) }
    private var confirmed: Bool {
        guard groups.count > (askIndices.max() ?? 0) else { return false }
        return zip(askIndices, answers).allSatisfy { idx, ans in
            ans.uppercased().filter { $0.isLetter || $0.isNumber } == groups[idx]
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                switch step {
                case .show: showScreen
                case .confirm: confirmScreen
                }
            }
            .navigationTitle("Ключ восстановления")
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(true)
            .toast($toast)
            .onAppear {
                if pdfURL == nil { pdfURL = Self.makePDF(key: key) }
                let count = max(groups.count, 2)
                var picks = Set<Int>()
                while picks.count < 2 { picks.insert(Int.random(in: 0..<count)) }
                askIndices = Array(picks).sorted()
            }
        }
    }

    // Экран 1 — показ ключа.
    private var showScreen: some View {
        Form {
            Section("Ваш ключ") {
                Text(key)
                    .font(.title2.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button { copyKey() } label: { Label("Скопировать", systemImage: "doc.on.doc") }
                if let pdfURL {
                    ShareLink(item: pdfURL) { Label("Сохранить как PDF / напечатать", systemImage: "square.and.arrow.up") }
                }
            }
            Section {
                Text("Лучше распечатайте или перепишите ключ на бумагу и храните отдельно от телефона. Если ключ лежит на этом же iPhone, его найдёт любой, кто получит доступ к телефону.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section {
                Button { answers = ["", ""]; step = .confirm } label: {
                    Text("Я сохранил ключ →").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                if allowSkip {
                    Button("Пропустить пока") { onSkip() }
                        .foregroundStyle(.secondary).frame(maxWidth: .infinity)
                }
            }
        }
    }

    // Экран 2 — проверка (ключа на экране нет).
    private var confirmScreen: some View {
        Form {
            Section("Проверка") {
                Text("Введите указанные группы из ключа, чтобы подтвердить, что вы его сохранили.")
                    .font(.footnote).foregroundStyle(.secondary)
                ForEach(0..<askIndices.count, id: \.self) { k in
                    HStack {
                        Text("Группа \(askIndices[k] + 1)").foregroundStyle(.secondary)
                        Spacer()
                        SecretTextField(text: $answers[k], placeholder: "____", secure: false, uppercase: true)
                            .frame(width: 90, height: 32)
                    }
                }
                if confirmError {
                    Text("Группы не совпадают. Проверьте ключ ещё раз.")
                        .font(.footnote).foregroundStyle(.red)
                }
            }
            Section {
                Button { if confirmed { onSaved() } else { confirmError = true } } label: {
                    Text("Подтвердить").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                Button("← Показать ключ снова") { confirmError = false; step = .show }
            }
        }
        .onChange(of: answers) { _, _ in confirmError = false }
    }

    private func copyKey() {
        Clipboard.copy(key)
        toast = Toast(text: "Скопировано. Очистится через 60 с")
    }

    static func makePDF(key: String) -> URL? {
        // Имя файла и метаданные ОДИНАКОВЫ для настоящего и ложного сейфа (без «ложный/второй»).
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(String(localized: "Stash — ключ восстановления.pdf"))
        let page = CGRect(x: 0, y: 0, width: 612, height: 792)
        let format = UIGraphicsPDFRendererFormat()
        format.documentInfo = [
            kCGPDFContextTitle as String: String(localized: "Stash — ключ восстановления"),
            kCGPDFContextCreator as String: "Stash",
        ]
        let renderer = UIGraphicsPDFRenderer(bounds: page, format: format)
        do {
            try renderer.writePDF(to: url) { ctx in
                ctx.beginPage()
                (String(localized: "Stash — ключ восстановления") as NSString).draw(
                    at: CGPoint(x: 40, y: 60),
                    withAttributes: [.font: UIFont.boldSystemFont(ofSize: 20)])
                (key as NSString).draw(
                    at: CGPoint(x: 40, y: 110),
                    withAttributes: [.font: UIFont.monospacedSystemFont(ofSize: 18, weight: .regular)])
                (String(localized: "Храните этот лист в надёжном месте. Этот ключ открывает ваш сейф, если вы забудете мастер-пароль. Любой, у кого есть этот ключ, может открыть сейф.") as NSString).draw(
                    in: CGRect(x: 40, y: 150, width: 532, height: 300),
                    withAttributes: [.font: UIFont.systemFont(ofSize: 13)])
            }
            return url
        } catch { return nil }
    }
}

/// Экран «Забыли пароль»: ввод ключа восстановления и нового мастер-пароля.
struct ForgotPasswordView: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var key = ""
    @State private var newPassword = ""
    @State private var confirm = ""
    @State private var reveal = false
    @State private var working = false
    @State private var errorText: String?

    private var assessment: PasswordAssessment { PasswordEvaluator.assess(newPassword) }
    private var canSubmit: Bool {
        RecoveryKey.normalize(key).count >= 8
        && newPassword.count >= PasswordEvaluator.minimumLength
        && newPassword == confirm && !working
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Ключ восстановления") {
                    SecretTextField(text: $key, placeholder: "XXXX-XXXX-…", secure: false, uppercase: true)
                        .frame(height: 32)
                }
                Section("Новый мастер-пароль") {
                    SecretTextField(text: $newPassword, placeholder: "Новый пароль", secure: !reveal)
                    SecretTextField(text: $confirm, placeholder: "Повторите новый пароль", secure: !reveal)
                    Toggle("Показать пароль", isOn: $reveal)
                    if !newPassword.isEmpty { PasswordStrengthView(assessment: assessment) }
                }
                if let errorText {
                    Text(errorText).foregroundStyle(.red).font(.footnote)
                }
                Section {
                    Button("Открыть сейф") { submit() }.disabled(!canSubmit)
                }
            }
            .navigationTitle("Забыли пароль")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } } }
            .onChange(of: key) { _, _ in errorText = nil }
            .onChange(of: newPassword) { _, _ in errorText = nil }
        }
    }

    private func submit() {
        working = true; errorText = nil
        Task {
            defer { working = false }
            do {
                try await model.recover(recoveryKey: key, newMasterPassword: newPassword)
                dismiss()
            } catch VaultError.wrongPassword {
                errorText = String(localized: "Этот ключ восстановления не подошёл.")
            } catch {
                errorText = String(localized: "Не удалось восстановить доступ.")
            }
        }
    }
}
