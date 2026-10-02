import SwiftUI
import PhotosUI
import Photos
import PDFKit
import UniformTypeIdentifiers
import StashCore

/// Секция вложений документа. Байты хранятся в записи (в слоте); отдельных файлов нет.
struct AttachmentsSection: View {
    let model: AppModel
    @Binding var attachments: [Attachment]
    var onScan: (() -> Void)? = nil
    var onLiveScan: (() -> Void)? = nil
    @State private var photoItem: PhotosPickerItem?
    @State private var showPDFImporter = false
    @State private var viewing: Attachment?
    @State private var pendingDeleteAssetID: String?
    @State private var showDeleteOriginal = false
    @State private var hint: String?

    var body: some View {
        Section("Вложения") {
            if let onLiveScan {
                Button { onLiveScan() } label: { Label("Считать с камеры", systemImage: "camera.viewfinder") }
            }
            if let onScan {
                Button { onScan() } label: { Label("Сфотографировать страницы", systemImage: "doc.viewfinder") }
            }
            ForEach(attachments) { att in
                Button { viewing = att } label: {
                    HStack(spacing: 12) {
                        AttachmentThumbnail(attachment: att)
                        Text(att.name).lineLimit(1)
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .onDelete { attachments.remove(atOffsets: $0) }

            // .shared() даёт локальный идентификатор, чтобы предложить удалить оригинал.
            PhotosPicker(selection: $photoItem, matching: .images, photoLibrary: .shared()) {
                Label("Добавить фото", systemImage: "photo.badge.plus")
            }
            Button { showPDFImporter = true } label: { Label("Добавить PDF", systemImage: "doc.badge.plus") }

            if let hint {
                Text(hint).font(.footnote).foregroundStyle(.secondary)
            }
        }
        .onChange(of: photoItem) { _, newItem in
            guard let newItem else { return }
            Task {
                if let data = try? await newItem.loadTransferable(type: Data.self),
                   let image = UIImage(data: data), let out = DocumentImage.jpeg(image) {
                    attachments.append(Attachment(name: "Фото \(attachments.count + 1).jpg", kind: .image, data: out.data))
                    if let id = newItem.itemIdentifier {
                        pendingDeleteAssetID = id
                        showDeleteOriginal = true
                    }
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
                    hint = String(localized: "Копия добавлена в Stash. Оригинал остался в «Файлах».")
                }
            }
        }
        .alert("Удалить оригинал из Фото?", isPresented: $showDeleteOriginal, presenting: pendingDeleteAssetID) { id in
            Button("Удалить", role: .destructive) { Self.deleteAsset(id) }
            Button("Оставить", role: .cancel) {}
        } message: { _ in
            Text("Копия уже сохранена в Stash. Удаление подтвердит система.")
        }
        .sheet(item: $viewing) { att in AttachmentViewer(model: model, attachment: att) }
    }

    /// Удаление оригинала из медиатеки. Система показывает собственное подтверждение.
    /// Выборку делаем ВНУТРИ change-блока, чтобы не тащить несендабельный PHFetchResult
    /// через границу очереди (Swift 6).
    static func deleteAsset(_ localID: String) {
        PHPhotoLibrary.shared().performChanges {
            let assets = PHAsset.fetchAssets(withLocalIdentifiers: [localID], options: nil)
            guard assets.count > 0 else { return }
            PHAssetChangeRequest.deleteAssets(assets)
        }
    }

}

/// Миниатюра вложения в списке — чтобы сразу видеть, что сохранилось.
struct AttachmentThumbnail: View {
    let attachment: Attachment
    var body: some View {
        Group {
            if attachment.kind == .image, let img = UIImage(data: attachment.data) {
                Image(uiImage: img).resizable().scaledToFill()
            } else {
                ZStack {
                    Color(uiColor: .secondarySystemBackground)
                    Image(systemName: "doc.richtext").foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: 44, height: 44)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(uiColor: .separator), lineWidth: 0.5))
    }
}

struct AttachmentViewer: View {
    let model: AppModel
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
                        .accessibilityLabel("Поделиться")
                }
            }
            .alert("Поделиться вложением?", isPresented: $confirmShare) {
                Button("Поделиться") {
                    if let url = Self.writeTemp(attachment) {
                        model.beginSystemScreen()
                        shareURL = url
                    }
                }
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
        if let url = shareURL {
            try? FileManager.default.removeItem(at: url)
            shareURL = nil
            model.endSystemScreen()
        }
    }

    static func writeTemp(_ attachment: Attachment) -> URL? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(attachment.name)
        do {
            try attachment.data.write(to: url, options: [.completeFileProtection])
            return url
        } catch { return nil }
    }
}

/// Просмотр изображения: вся страница вписана в экран (aspect fit), pinch-zoom и
/// двойной тап. Масштабы считает UIScrollView ПОСЛЕ layout (в layoutSubviews),
/// поэтому при открытии видно всю страницу без размытия, а не угол в 1×.
struct ZoomableImage: UIViewRepresentable {
    let image: UIImage

    func makeUIView(context: Context) -> ZoomImageScrollView {
        let view = ZoomImageScrollView()
        view.setImage(image)
        let doubleTap = UITapGestureRecognizer(target: view, action: #selector(ZoomImageScrollView.handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        view.addGestureRecognizer(doubleTap)
        return view
    }

    func updateUIView(_ view: ZoomImageScrollView, context: Context) {
        view.setImage(image)
    }
}

/// UIScrollView с вписанным изображением; min/zoom-scale пересчитываются в layoutSubviews.
final class ZoomImageScrollView: UIScrollView, @preconcurrency UIScrollViewDelegate {
    private let imageView = UIImageView()
    private var lastBoundsSize: CGSize = .zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        delegate = self
        showsVerticalScrollIndicator = false
        showsHorizontalScrollIndicator = false
        bouncesZoom = true
        imageView.contentMode = .scaleAspectFit
        imageView.isUserInteractionEnabled = true
        addSubview(imageView)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }

    func setImage(_ image: UIImage) {
        if imageView.image !== image {
            imageView.image = image
            imageView.frame = CGRect(origin: .zero, size: image.size)
            contentSize = image.size
            lastBoundsSize = .zero  // пересчитать масштаб в layoutSubviews
            setNeedsLayout()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let image = imageView.image, bounds.width > 0, bounds.height > 0 else { return }
        if bounds.size != lastBoundsSize {
            lastBoundsSize = bounds.size
            let sx = bounds.width / image.size.width
            let sy = bounds.height / image.size.height
            let fit = min(sx, sy)
            minimumZoomScale = fit
            maximumZoomScale = max(fit * 4, fit)
            zoomScale = fit
        }
        centerImage()
    }

    private func centerImage() {
        let w = imageView.frame.width, h = imageView.frame.height
        let insetX = max(0, (bounds.width - w) / 2)
        let insetY = max(0, (bounds.height - h) / 2)
        contentInset = UIEdgeInsets(top: insetY, left: insetX, bottom: insetY, right: insetX)
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }
    func scrollViewDidZoom(_ scrollView: UIScrollView) { centerImage() }

    @objc func handleDoubleTap(_ g: UITapGestureRecognizer) {
        if zoomScale > minimumZoomScale {
            setZoomScale(minimumZoomScale, animated: true)
        } else {
            setZoomScale(min(minimumZoomScale * 3, maximumZoomScale), animated: true)
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
