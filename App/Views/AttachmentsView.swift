import SwiftUI
import PhotosUI
import PDFKit
import UniformTypeIdentifiers
import StashCore

/// Секция вложений документа. Байты хранятся в записи (в слоте); отдельных файлов нет.
struct AttachmentsSection: View {
    @Binding var attachments: [Attachment]
    @State private var photoItem: PhotosPickerItem?
    @State private var showPDFImporter = false
    @State private var viewing: Attachment?

    var body: some View {
        Section("Вложения") {
            ForEach(attachments) { att in
                Button { viewing = att } label: {
                    Label(att.name, systemImage: att.kind == .pdf ? "doc.richtext" : "photo")
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .onDelete { attachments.remove(atOffsets: $0) }

            PhotosPicker(selection: $photoItem, matching: .images) {
                Label("Добавить фото", systemImage: "photo.badge.plus")
            }
            Button { showPDFImporter = true } label: { Label("Добавить PDF", systemImage: "doc.badge.plus") }
        }
        .onChange(of: photoItem) { _, newItem in
            guard let newItem else { return }
            Task {
                if let data = try? await newItem.loadTransferable(type: Data.self),
                   let image = UIImage(data: data), let jpeg = Self.compressed(image) {
                    attachments.append(Attachment(name: "Фото \(attachments.count + 1).jpg", kind: .image, data: jpeg))
                }
                photoItem = nil
            }
        }
        .fileImporter(isPresented: $showPDFImporter, allowedContentTypes: [.pdf]) { result in
            if case let .success(url) = result {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                if let data = try? Data(contentsOf: url) {
                    attachments.append(Attachment(name: url.lastPathComponent, kind: .pdf, data: data))
                }
            }
        }
        .sheet(item: $viewing) { att in AttachmentViewer(attachment: att) }
    }

    /// Сжатие изображения: длинная сторона ≤ 2500 px, JPEG.
    static func compressed(_ image: UIImage, maxSide: CGFloat = 2500, quality: CGFloat = 0.7) -> Data? {
        let longest = max(image.size.width, image.size.height)
        let scale = longest > maxSide ? maxSide / longest : 1
        let target = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: target)
        let resized = renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: target)) }
        return resized.jpegData(compressionQuality: quality)
    }
}

struct AttachmentViewer: View {
    let attachment: Attachment
    @Environment(\.dismiss) private var dismiss
    @State private var shareURL: URL?
    @State private var confirmShare = false

    var body: some View {
        NavigationStack {
            Group {
                if attachment.kind == .pdf, let doc = PDFDocument(data: attachment.data) {
                    PDFKitView(document: doc)
                } else if let image = UIImage(data: attachment.data) {
                    ZoomableImage(image: image)
                } else {
                    Text("Не удалось открыть вложение").foregroundStyle(.secondary)
                }
            }
            .navigationTitle(attachment.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Закрыть") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { confirmShare = true } label: { Image(systemName: "square.and.arrow.up") }
                }
            }
            .alert("Поделиться вложением?", isPresented: $confirmShare) {
                Button("Поделиться") { shareURL = Self.writeTemp(attachment) }
                Button("Отмена", role: .cancel) {}
            } message: {
                Text("Файл временно покинет Stash и попадёт в выбранное приложение.")
            }
            .sheet(isPresented: Binding(get: { shareURL != nil }, set: { if !$0 { cleanup() } })) {
                if let url = shareURL { ShareSheet(items: [url]) }
            }
            .onDisappear { cleanup() }
        }
    }

    private func cleanup() {
        if let url = shareURL { try? FileManager.default.removeItem(at: url); shareURL = nil }
    }

    static func writeTemp(_ attachment: Attachment) -> URL? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(attachment.name)
        do {
            try attachment.data.write(to: url, options: [.completeFileProtection])
            return url
        } catch { return nil }
    }
}

struct ZoomableImage: View {
    let image: UIImage
    @State private var scale: CGFloat = 1

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .scaleEffect(scale)
                .gesture(MagnificationGesture().onChanged { scale = max(1, min($0, 5)) }
                    .onEnded { _ in if scale < 1 { scale = 1 } })
        }
    }
}

struct PDFKitView: UIViewRepresentable {
    let document: PDFDocument
    func makeUIView(context: Context) -> PDFView {
        let view = PDFView(); view.autoScales = true; view.document = document; return view
    }
    func updateUIView(_ view: PDFView, context: Context) { view.document = document }
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
