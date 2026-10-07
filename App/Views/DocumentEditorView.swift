import SwiftUI
import UIKit
import AVFoundation
import VisionKit
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
    @State private var showCameraDenied = false
    @State private var scanNote: String?
    @State private var recognizedText: String?
    /// Ключи полей, заполненных из MRZ (подсвечиваются до правки/таймаута).
    @State private var mrzFilledKeys: Set<String> = []
    @State private var pendingMRZ: MRZResult?
    @State private var confirmFillFromScan = false
    @State private var showLiveScanner = false

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

    /// Кнопки сканирования в блоке вложений — только для существующего документа.
    private var attachmentsScanAction: (() -> Void)? {
        guard isExisting else { return nil }
        return { startScan() }
    }
    private var attachmentsLiveScanAction: (() -> Void)? {
        guard isExisting, LiveMRZScannerView.isSupported else { return nil }
        return { startLiveScan() }
    }

    private var formBody: some View {
        Form {
            headerSection
            if !isExisting { scanBlock }   // новый документ: скан первым блоком
            fieldsSection
            freeFieldsSection
            // существующий документ: кнопки скана — в блоке вложений
            AttachmentsSection(model: model, attachments: $attachments,
                               onScan: attachmentsScanAction, onLiveScan: attachmentsLiveScanAction)
            if isExisting { scanFeedback }
            expirySection
            noteSection
            if isExisting { deleteSection }
        }
    }

    var body: some View {
        formBody
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
        .fullScreenCover(isPresented: $showScanner, onDismiss: { model.endSystemScreen() }) {
            DocumentScannerView { images in
                showScanner = false   // SwiftUI снимает презентацию; сканер себя не закрывает
                handleScan(images)
            }
            .ignoresSafeArea()
        }
        .fullScreenCover(isPresented: $showLiveScanner, onDismiss: { model.endSystemScreen() }) {
            if LiveMRZScannerView.isSupported {
                LiveMRZScannerView(prefer: expectedFormat()) { mrz in
                    showLiveScanner = false
                    handleLiveResult(mrz)
                }
                .ignoresSafeArea()
            }
        }
        .alert("Нужен доступ к камере", isPresented: $showCameraDenied) {
            Button("Открыть Настройки") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Разрешите доступ к камере в Настройках, чтобы сканировать документы.")
        }
        .onChange(of: hasExpiry) { _, now in
            if now { Task { await ExpiryNotifications.requestAuthorization() } }
        }
        .alert("Заполнить пустые поля из скана?", isPresented: $confirmFillFromScan, presenting: pendingMRZ) { mrz in
            Button("Заполнить") { applyMRZ(mrz, onlyEmpty: true) }
            Button("Отмена", role: .cancel) {}
        } message: { _ in
            Text("Уже заполненные поля не изменятся.")
        }
    }

    // MARK: - Сканирование

    /// Предпроверка перед показом камеры: без неё контроллер мог завершаться сразу и
    /// экран «схлопывался» молча. Теперь недоступность показывает причину.
    private func startScan() {
        recognizedText = nil
        guard VNDocumentCameraViewController.isSupported else {
            scanNote = String(localized: "Сканирование недоступно на этом устройстве.")
            return
        }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            presentScanner()
        case .notDetermined:
            model.beginSystemScreen()
            Task {
                let granted = await AVCaptureDevice.requestAccess(for: .video)
                model.endSystemScreen()
                if granted { presentScanner() } else { showCameraDenied = true }
            }
        default:
            showCameraDenied = true
        }
    }

    private func presentScanner() {
        model.beginSystemScreen()
        showScanner = true
    }

    private func startLiveScan() {
        model.beginSystemScreen()
        showLiveScanner = true
    }

    private func handleLiveResult(_ mrz: MRZResult?) {
        if let mrz, mrz.checkDigitsValid {
            fillFromMRZ(mrz)
        } else {
            scanNote = String(localized: "Не получилось — заполните вручную или сделайте фото")
        }
    }

    /// Решает, как заполнять: в существующем документе с заполненными полями — спросить.
    private func fillFromMRZ(_ mrz: MRZResult) {
        recognizedText = nil
        if isExisting && hasAnyRecommendedFieldFilled {
            pendingMRZ = mrz
            confirmFillFromScan = true
        } else {
            applyMRZ(mrz, onlyEmpty: false)
        }
    }

    private func handleScan(_ images: [UIImage]) {
        guard !images.isEmpty else { return }
        scanNote = nil
        // Нормализуем (ориентация .up, длинная сторона ≤2500) ОДИН раз; эти же картинки
        // идут и во вложение, и в OCR — что видно, то и распознаётся.
        var normalizedImages: [UIImage] = []
        var lastPixel = CGSize.zero
        for (i, img) in images.enumerated() {
            let norm = DocumentImage.normalized(img)
            normalizedImages.append(norm.image)
            lastPixel = norm.pixelSize
            if let data = norm.image.jpegData(compressionQuality: 0.8) {
                attachments.append(Attachment(name: "Скан \(attachments.count + i + 1).jpg", kind: .image, data: data))
            }
        }
        let orientationRaw = images.first?.imageOrientation.rawValue ?? 0
        let prefer = expectedFormat()
        Task {
            var mrzRows: [[String]] = []
            var joins = 0
            for img in normalizedImages {
                let a = await DocumentOCR.mrzAssembledRows(img)
                mrzRows += a.rows; joins += a.joins
            }
            let (mrz, diag) = MRZParser.parseRecovering(rows: mrzRows, prefer: prefer)

            var general = ""
            for img in normalizedImages { general += await DocumentOCR.recognizeText(img) + "\n" }
            let generalTrimmed = general.trimmingCharacters(in: .whitespacesAndNewlines)
            let lineCount = generalTrimmed.isEmpty ? 0 : generalTrimmed.split(whereSeparator: \.isNewline).count

            model.setScanDiagnostics(ScanDiagnostics(
                imageWidth: Int(lastPixel.width), imageHeight: Int(lastPixel.height),
                orientationRaw: orientationRaw, recognizedLineCount: lineCount,
                mrzCandidateCount: diag.candidateLineCount, joinCount: joins,
                detectedFormat: diag.detectedFormat, failedChecks: diag.failedChecks,
                recovered: diag.recovered, attempts: diag.attempts))

            if let mrz, mrz.checkDigitsValid {
                fillFromMRZ(mrz)
            } else {
                // Скан уже прикреплён. MRZ не распозналась/не прошла — предлагаем ручной ввод,
                // а найденный текст показываем, чтобы было откуда скопировать.
                scanNote = String(localized: "Не удалось распознать — заполните вручную")
                recognizedText = generalTrimmed.isEmpty ? nil : generalTrimmed
            }
        }
    }

    private var hasAnyRecommendedFieldFilled: Bool {
        DocumentFields.recommended(for: type).contains { !(fields[$0.rawValue] ?? "").isEmpty }
    }

    /// Заполняет поля из MRZ. onlyEmpty=true — не перезаписывает уже заполненные.
    private func applyMRZ(_ mrz: MRZResult, onlyEmpty: Bool) {
        var filled: Set<String> = []
        func put(_ key: DocumentFieldKey, _ value: String) {
            guard !value.isEmpty else { return }
            if onlyEmpty, !(fields[key.rawValue] ?? "").isEmpty { return }
            fields[key.rawValue] = value
            filled.insert(key.rawValue)
        }
        put(.number, mrz.documentNumber)
        put(.fullName, [mrz.surname, mrz.givenNames].filter { !$0.isEmpty }.joined(separator: " "))
        put(.country, mrz.nationality)
        if let birth = mrz.birthDate { put(.birthDate, Self.isoDate(birth)) }
        if let exp = mrz.expiryDate, !(onlyEmpty && hasExpiry) { hasExpiry = true; expiry = exp }
        scanNote = String(localized: "Заполнено из скана — проверьте поля")
        mrzFilledKeys = filled
        Task { try? await Task.sleep(nanoseconds: 8_000_000_000); mrzFilledKeys = [] }
    }

    private static func isoDate(_ date: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: date)
    }

    // MARK: - Секции формы (разбиты, чтобы не упираться в лимит тайп-чекера)

    @ViewBuilder private var headerSection: some View {
        Section {
            TextField("Название", text: $title)
            Picker("Тип документа", selection: $type) {
                ForEach(DocumentType.allCases, id: \.self) { Text(Self.typeName($0)).tag($0) }
            }
            Toggle("Избранное", isOn: $favorite)
        }
    }

    @ViewBuilder private var fieldsSection: some View {
        Section("Поля") {
            ForEach(DocumentFields.recommended(for: type), id: \.self) { key in
                fieldRow(key)
            }
        }
    }

    @ViewBuilder private func fieldRow(_ key: DocumentFieldKey) -> some View {
        let highlighted = mrzFilledKeys.contains(key.rawValue)
        HStack {
            Text(Self.fieldLabel(key)).foregroundStyle(.secondary)
            Spacer()
            TextField("", text: fieldBinding(key.rawValue))
                .multilineTextAlignment(.trailing)
        }
        .listRowBackground(highlighted ? Color.accentColor.opacity(0.12) : Color(uiColor: .secondarySystemGroupedBackground))
    }

    @ViewBuilder private var freeFieldsSection: some View {
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
    }

    @ViewBuilder private var expirySection: some View {
        Section("Срок действия") {
            Toggle("Есть срок действия", isOn: $hasExpiry)
            if hasExpiry {
                DatePicker("Действителен до", selection: $expiry, displayedComponents: .date)
            }
        }
    }

    @ViewBuilder private var noteSection: some View {
        Section("Заметка") {
            TextField("Заметка", text: $notes, axis: .vertical).lineLimit(1...6)
        }
    }

    @ViewBuilder private var deleteSection: some View {
        Section {
            Button("Удалить запись", role: .destructive) { confirmDelete = true }
                .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Блоки сканирования

    /// Крупный блок для нового документа: кнопка + подсказка, после скана — миниатюра и статус.
    @ViewBuilder private var scanBlock: some View {
        Section {
            if LiveMRZScannerView.isSupported {
                Button { startLiveScan() } label: {
                    VStack(spacing: 6) {
                        Image(systemName: "camera.viewfinder").font(.largeTitle)
                        Text("Считать с камеры").font(.headline)
                        Text("Поля заполнятся автоматически").font(.footnote).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 8)
                }
            }
            Button { startScan() } label: {
                Label("Сфотографировать страницы", systemImage: "doc.viewfinder")
            }
            if let first = attachments.first(where: { $0.kind == .image }) {
                HStack(spacing: 12) {
                    AttachmentThumbnail(attachment: first)
                    if let scanNote { Text(scanNote).font(.footnote).foregroundStyle(.secondary) }
                }
            } else if let scanNote {
                Text(scanNote).font(.footnote).foregroundStyle(.secondary)
            }
            recognizedDisclosure
        }
    }

    /// Статус скана для существующего документа (кнопка — в блоке вложений).
    @ViewBuilder private var scanFeedback: some View {
        if scanNote != nil || (recognizedText?.isEmpty == false) {
            Section {
                if let scanNote { Text(scanNote).font(.footnote).foregroundStyle(.secondary) }
                recognizedDisclosure
            }
        }
    }

    @ViewBuilder private var recognizedDisclosure: some View {
        if let recognizedText, !recognizedText.isEmpty {
            DisclosureGroup("Распознанный текст") {
                Text(recognizedText)
                    .font(.footnote.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func expectedFormat() -> MRZResult.Format? {
        switch type {
        case .passport, .foreignPassport: return .td3
        case .idCard, .residencePermit: return .td1
        default: return nil
        }
    }

    private func fieldBinding(_ key: String) -> Binding<String> {
        Binding(get: { fields[key] ?? "" }, set: { fields[key] = $0; mrzFilledKeys.remove(key) })
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

    static func typeName(_ type: DocumentType) -> LocalizedStringResource {
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

    static func fieldLabel(_ key: DocumentFieldKey) -> LocalizedStringResource {
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
