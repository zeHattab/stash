import SwiftUI
import StashCore

/// Массовый импорт кодов из Google Authenticator (otpauth-migration с несколькими аккаунтами):
/// сканируем/вставляем ссылку, отмечаем нужные, каждый выбранный — отдельный логин с кодом.
struct TOTPImportView: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var raw = ""
    @State private var configs: [TOTPConfig] = []
    @State private var selected: Set<Int> = []
    @State private var error: String?
    @State private var showScanner = false

    var body: some View {
        NavigationStack {
            Form {
                if configs.isEmpty {
                    Section {
                        if QRScannerView.isSupported {
                            Button { startScan() } label: { Label("Сканировать QR экспорта", systemImage: "qrcode.viewfinder") }
                        }
                        SecretTextField(text: $raw, placeholder: "otpauth-migration://offline?data=…", secure: false)
                        Button("Разобрать") { parse(raw) }
                            .disabled(raw.trimmingCharacters(in: .whitespaces).isEmpty)
                    } footer: {
                        Text("В Google Authenticator: «Перенести аккаунты» → «Экспортировать» → покажется QR. Отсканируйте его здесь.")
                    }
                    if let error { Text(error).foregroundStyle(.red).font(.footnote) }
                } else {
                    Section {
                        ForEach(configs.indices, id: \.self) { i in
                            Button {
                                if selected.contains(i) { selected.remove(i) } else { selected.insert(i) }
                            } label: {
                                HStack {
                                    Image(systemName: selected.contains(i) ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(selected.contains(i) ? Color.accentColor : Color.secondary)
                                    VStack(alignment: .leading) {
                                        Text(label(configs[i])).foregroundStyle(.primary)
                                        if let issuer = configs[i].issuer, !issuer.isEmpty,
                                           configs[i].account?.isEmpty == false {
                                            Text(configs[i].account ?? "").font(.footnote).foregroundStyle(.secondary)
                                        }
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    } header: {
                        Text("Найдено кодов: \(configs.count)")
                    }
                    Section {
                        Button("Импортировать выбранные") { importSelected() }
                            .disabled(selected.isEmpty)
                    }
                }
            }
            .navigationTitle("Импорт кодов 2FA")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
            }
            .fullScreenCover(isPresented: $showScanner, onDismiss: { model.endSystemScreen() }) {
                if QRScannerView.isSupported {
                    QRScannerView { result in
                        showScanner = false
                        if let result { parse(result) }
                    }
                    .ignoresSafeArea()
                    .overlay(alignment: .bottomTrailing) {
                        Button("Отмена") { showScanner = false }.padding().tint(.white)
                    }
                }
            }
        }
    }

    private func label(_ c: TOTPConfig) -> String {
        [c.issuer, c.account].compactMap { $0 }.first { !$0.isEmpty } ?? String(localized: "Код 2FA")
    }

    private func startScan() {
        model.beginSystemScreen()
        showScanner = true
    }

    private func parse(_ string: String) {
        switch OTPAuth.parseMigration(string) {
        case .success(let list) where !list.isEmpty:
            configs = list
            selected = Set(list.indices)
            error = nil
        case .success:
            error = String(localized: "В экспорте нет кодов TOTP.")
        case .failure:
            error = String(localized: "Не удалось разобрать экспорт Google Authenticator.")
        }
    }

    private func importSelected() {
        let chosen = configs.enumerated().filter { selected.contains($0.offset) }.map(\.element)
        Task {
            for cfg in chosen {
                let item = VaultItem(
                    kind: .login(username: cfg.account ?? "", password: "", urls: [],
                                 totpSecret: OTPAuth.makeURL(from: cfg)),
                    title: label(cfg))
                try? await model.save(item)
            }
            dismiss()
        }
    }
}
