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

    @State private var askIndices: [Int] = [0, 1]
    @State private var answers: [String] = ["", ""]
    @State private var pdfURL: URL?
    @State private var toast: Toast?

    private var groups: [String] { key.split(separator: "-").map(String.init) }
    private var confirmed: Bool {
        guard groups.count > askIndices.max() ?? 0 else { return false }
        return zip(askIndices, answers).allSatisfy { idx, ans in
            ans.uppercased().filter { $0.isLetter || $0.isNumber } == groups[idx]
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Ключ восстановления открывает сейф, если вы забудете мастер-пароль. Сохраните его в надёжном месте вне телефона. Мы не храним его копию.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("Ваш ключ") {
                    Text(key)
                        .font(.title3.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button { copyKey() } label: { Label("Скопировать", systemImage: "doc.on.doc") }
                    if let pdfURL {
                        ShareLink(item: pdfURL) { Label("Сохранить как PDF / напечатать", systemImage: "square.and.arrow.up") }
                    }
                }
                Section("Подтвердите, что сохранили") {
                    ForEach(0..<askIndices.count, id: \.self) { k in
                        HStack {
                            Text("Группа \(askIndices[k] + 1)").foregroundStyle(.secondary)
                            Spacer()
                            TextField("____", text: $answers[k])
                                .multilineTextAlignment(.trailing)
                                .textInputAutocapitalization(.characters)
                                .autocorrectionDisabled()
                                .frame(width: 90)
                        }
                    }
                    Button("Я сохранил ключ") { onSaved() }
                        .disabled(!confirmed)
                }
                if allowSkip {
                    Section {
                        Button("Пропустить пока") { onSkip() }
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Ключ восстановления")
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(true)
            .toast($toast)
            .onAppear {
                pdfURL = Self.makePDF(key: key)
                let count = max(groups.count, 2)
                var picks = Set<Int>()
                while picks.count < 2 { picks.insert(Int.random(in: 0..<count)) }
                askIndices = Array(picks).sorted()
                answers = ["", ""]
            }
        }
    }

    private func copyKey() {
        Clipboard.copy(key)
        toast = Toast(text: "Скопировано. Очистится через 60 с")
    }

    static func makePDF(key: String) -> URL? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("StashRecoveryKey.pdf")
        let page = CGRect(x: 0, y: 0, width: 612, height: 792)
        let renderer = UIGraphicsPDFRenderer(bounds: page)
        do {
            try renderer.writePDF(to: url) { ctx in
                ctx.beginPage()
                ("Stash — ключ восстановления" as NSString).draw(
                    at: CGPoint(x: 40, y: 60),
                    withAttributes: [.font: UIFont.boldSystemFont(ofSize: 20)])
                (key as NSString).draw(
                    at: CGPoint(x: 40, y: 110),
                    withAttributes: [.font: UIFont.monospacedSystemFont(ofSize: 18, weight: .regular)])
                ("Храните этот лист в надёжном месте. Этот ключ открывает ваш сейф, если вы забудете мастер-пароль. Любой, у кого есть этот ключ, может открыть сейф." as NSString).draw(
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
                    TextField("XXXX-XXXX-…", text: $key)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                }
                Section("Новый мастер-пароль") {
                    Group {
                        if reveal { TextField("Новый пароль", text: $newPassword) }
                        else { SecureField("Новый пароль", text: $newPassword) }
                    }
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Group {
                        if reveal { TextField("Повторите новый пароль", text: $confirm) }
                        else { SecureField("Повторите новый пароль", text: $confirm) }
                    }
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
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
                errorText = "Этот ключ восстановления не подошёл."
            } catch {
                errorText = "Не удалось восстановить доступ."
            }
        }
    }
}
