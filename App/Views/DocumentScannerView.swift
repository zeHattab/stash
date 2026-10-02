import SwiftUI
import VisionKit
import Vision
import os

private let scanLog = Logger(subsystem: "com.portie24.stash", category: "scanner")

/// Сканер документов (VisionKit). Возвращает страницы в `onComplete` и НЕ закрывает себя сам —
/// родитель снимает презентацию через биндинг (иначе само-dismiss конфликтует со SwiftUI и
/// экран схлопывается сразу). В каждый метод делегата — лог (без персональных данных).
struct DocumentScannerView: UIViewControllerRepresentable {
    var onComplete: ([UIImage]) -> Void

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        scanLog.info("make VNDocumentCameraViewController (supported=\(VNDocumentCameraViewController.isSupported, privacy: .public))")
        let controller = VNDocumentCameraViewController()
        controller.delegate = context.coordinator
        return controller
    }
    func updateUIViewController(_ controller: VNDocumentCameraViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(onComplete: onComplete) }

    @MainActor
    final class Coordinator: NSObject, @preconcurrency VNDocumentCameraViewControllerDelegate {
        let onComplete: ([UIImage]) -> Void
        init(onComplete: @escaping ([UIImage]) -> Void) { self.onComplete = onComplete }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController,
                                          didFinishWith scan: VNDocumentCameraScan) {
            var images: [UIImage] = []
            for page in 0..<scan.pageCount { images.append(scan.imageOfPage(at: page)) }
            scanLog.info("delegate didFinish pages=\(images.count, privacy: .public)")
            onComplete(images)
        }
        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
            scanLog.info("delegate didCancel")
            onComplete([])
        }
        func documentCameraViewController(_ controller: VNDocumentCameraViewController,
                                          didFailWithError error: Error) {
            scanLog.error("delegate didFail: \(error.localizedDescription, privacy: .public)")
            onComplete([])
        }
    }
}

/// Распознавание текста на устройстве (Vision), ru + en, без сети.
enum DocumentOCR {
    static func recognizeText(_ image: UIImage) async -> String {
        guard let cg = image.cgImage else { return "" }
        return await Task.detached(priority: .userInitiated) { () -> String in
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false
            request.recognitionLanguages = ["ru-RU", "en-US"]
            let handler = VNImageRequestHandler(cgImage: cg, options: [:])
            try? handler.perform([request])
            let observations = request.results ?? []
            return observations.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
        }.value
    }
}
