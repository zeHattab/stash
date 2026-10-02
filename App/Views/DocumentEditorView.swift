import SwiftUI
import StashCore

struct DocumentEditorView: View {
    let model: AppModel
    let original: VaultItem
    var onCollect: ((VaultItem) -> Void)? = nil

    @Environment(\.dismiss) private var dismiss

    @State private var type: DocumentType
    @State private var title: String
    @State private var notes: String
    @State private var favorite: Bool
    @State private var fields: [String: String]
    @State private var freeFields: [FreeField]
    @State private var hasExpiry: Bool
    @State private var expiry: Date
    @State private var attachments: [Attachment]
    @State private var confirmDelete = false
    @State private var showScanner = false
    @State private var scanNote: String?

    struct FreeField: Identifiable { let id = UUID(); var name: String; var value: String }

    init(model: AppModel, original: VaultItem, onCollect: ((VaultItem) -> Void)? = nil) {
        self.model = model
        self.original = original
        self.onCollect = onCollect
        var t: DocumentType = .other
        var f: [String: String] = [:]
        var exp: Date? = nil
        if case let .document(docType, docFields, expiresAt, _) = original.kind {
            t = docType; f = docFields; exp = expiresAt
        }
        _type = State(initialValue: t)
        _title = State(initialValue: original.title)
        _notes = State(initialValue: original.notes)
        _favorite = State(initialValue: original.favorite)
        // Рекомендуемые ключи уходят в fields, остальные — в свободные поля.
        let recommended = Set(DocumentFields.recommended(for: t).map(\.rawValue))
        _fields = State(initialValue: f.filter { recommended.contains($0.key) })
        _freeFields = State(initialValue: f.filter { !recommended.contains($0.key) }
            .map { FreeField(name: $0.key, value: $0.value) })
        _hasExpiry = State(initialValue: exp != nil)
        _expiry = State(initialValue: exp ?? Date())
        _attachments = State(initialValue: original.attachments ?? [])
    }

    private var isExisting: Bool { model.items.contains { $0.id == original.id } }

    var body: some View {
        Form {
            Section {
                TextField("Название", text: $title)
                Picker("Тип документа", selection: $type) {
                    ForEach(DocumentType.allCases, id: \.self) { Text(Self.typeName($0)).tag($0) }
                }
                Toggle("Избранное", isOn: $favorite)
            }

            Section("Поля") {
                ForEach(DocumentFields.recommended(for: type), id: \.self) { key in
                    HStack {
                        Text(Self.fieldLabel(key)).foregroundStyle(.secondary)
                        Spacer()
                        TextField("", text: fieldBinding(key.rawValue))
                            .multilineTextAlignment(.trailing)
                    }
                }
            }

            Section("Дополнительные поля") {
                ForEach($freeFields) { $f in
                    HStack {
                        TextField("Название", text: $f.name).frame(maxWidth: 140)
                        Divider()
                        TextField("Значение", text: $f.value)
                    }
                }
                .onDelete { freeFields.remove(atOffsets: $0) }
                Button { freeFields.append(FreeField(name: "", value: "")) } label: {
                    Label("Добавить поле", systemImage: "plus")
                }.font(.footnote)
            }

            Section {
                Button { showScanner = true } label: { Label("Сканировать документ", systemImage: "doc.viewfinder") }
                if let scanNote {
                    Text(scanNote).font(.footnote).foregroundStyle(.secondary)
                }
            }

            AttachmentsSection(attachments: $attachments)

            Section("Срок действия") {
                Toggle("Есть срок действия", isOn: $hasExpiry)
                if hasExpiry {
                    DatePicker("Действителен до", selection: $expiry, displayedComponents: .date)
                }
            }

            Section("Заметка") {
                TextField("Заметка", text: $notes, axis: .vertical).lineLimit(1...6)
            }

            if isExisting {
                Section {
                    Button("Удалить запись", role: .destructive) { confirmDelete = true }
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .navigationTitle(isExisting ? "Документ" : "Новый документ")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Готово") { save() }
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .alert("Удалить запись?", isPresented: $confirmDelete) {
            Button("Удалить", role: .destructive) {
                Task { try? await model.delete(original.id); dismiss() }
            }
            Button("Отмена", role: .cancel) {}
        }
        .fullScreenCover(isPresented: $showScanner) {
            DocumentScannerView(onComplete: handleScan).ignoresSafeArea()
        }
        .onChange(of: hasExpiry) { _, now in
            if now { Task { await ExpiryNotifications.requestAuthorization() } }
        }
    }

    private func handleScan(_ images: [UIImage]) {
        guard !images.isEmpty else { return }
        for (i, img) in images.enumerated() {
            if let jpeg = AttachmentsSection.compressed(img) {
                attachments.append(Attachment(name: "Скан \(attachments.count + i + 1).jpg", kind: .image, data: jpeg))
            }
        }
        Task {
            var text = ""
            for img in images { text += await DocumentOCR.recognizeText(img) + "\n" }
            guard let mrz = MRZParser.parse(text) else { return }
            if mrz.checkDigitsValid {
                fields[DocumentFieldKey.number.rawValue] = mrz.documentNumber
                let name = [mrz.surname, mrz.givenNames].filter { !$0.isEmpty }.joined(separator: " ")
                if !name.isEmpty { fields[DocumentFieldKey.fullName.rawValue] = name }
                if !mrz.nationality.isEmpty { fields[DocumentFieldKey.country.rawValue] = mrz.nationality }
                if let birth = mrz.birthDate { fields[DocumentFieldKey.birthDate.rawValue] = Self.isoDate(birth) }
                if let exp = mrz.expiryDate { hasExpiry = true; expiry = exp }
                scanNote = "Поля заполнены из MRZ — проверьте их."
            } else {
                scanNote = "MRZ не прошёл проверку — заполните поля вручную."
            }
        }
    }

    private static func isoDate(_ date: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: date)
    }

    private func fieldBinding(_ key: String) -> Binding<String> {
        Binding(get: { fields[key] ?? "" }, set: { fields[key] = $0 })
    }

    private func save() {
        var merged: [String: String] = [:]
        for (k, v) in fields where !v.trimmingCharacters(in: .whitespaces).isEmpty { merged[k] = v }
        for f in freeFields {
            let name = f.name.trimmingCharacters(in: .whitespaces)
            let value = f.value.trimmingCharacters(in: .whitespaces)
            if !name.isEmpty && !value.isEmpty { merged[name] = value }
        }
        var item = original
        item.title = title.trimmingCharacters(in: .whitespaces)
        item.notes = notes
        item.favorite = favorite
        let attachmentIDs: [UUID] = {
            if case let .document(_, _, _, ids) = original.kind { return ids }
            return []
        }()
        item.kind = .document(type: type, fields: merged,
                              expiresAt: hasExpiry ? expiry : nil, attachmentIDs: attachmentIDs)
        item.attachments = attachments.isEmpty ? nil : attachments
        if let onCollect {
            onCollect(item); dismiss()
        } else {
            Task { try? await model.save(item); dismiss() }
        }
    }

    // MARK: - Подписи

    static func typeName(_ type: DocumentType) -> String {
        switch type {
        case .passport: return "Паспорт"
        case .foreignPassport: return "Загранпаспорт"
        case .residencePermit: return "ВНЖ"
        case .idCard: return "ID-карта"
        case .driverLicense: return "Водительские права"
        case .insurance: return "Страховка"
        case .certificate: return "Свидетельство"
        case .other: return "Документ"
        }
    }

    static func fieldLabel(_ key: DocumentFieldKey) -> String {
        switch key {
        case .number: return "Номер"
        case .fullName: return "ФИО"
        case .birthDate: return "Дата рождения"
        case .issueDate: return "Дата выдачи"
        case .issuer: return "Кем выдан"
        case .authority: return "Орган выдачи"
        case .series: return "Серия"
        case .category: return "Категория"
        case .policyNumber: return "Номер полиса"
        case .country: return "Страна"
        }
    }
}
