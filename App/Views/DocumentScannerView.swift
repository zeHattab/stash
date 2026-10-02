import SwiftUI
import VisionKit
import Vision
import ImageIO
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

/// Распознавание текста на устройстве (Vision), без сети.
enum DocumentOCR {
    /// Базовый проход: язык(и), ориентация, опциональная область интереса (ROI в
    /// нормализованных координатах Vision — начало в левом НИЖНЕМ углу).
    private static func recognizeLines(cg: CGImage, orientation: CGImagePropertyOrientation,
                                       languages: [String], roi: CGRect?) async -> [String] {
        await Task.detached(priority: .userInitiated) { () -> [String] in
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false
            request.recognitionLanguages = languages
            if let roi { request.regionOfInterest = roi }
            let handler = VNImageRequestHandler(cgImage: cg, orientation: orientation, options: [:])
            try? handler.perform([request])
            let observations = request.results ?? []
            return observations.compactMap { $0.topCandidates(1).first?.string }
        }.value
    }

    /// Строки-кандидаты MRZ: латиница (en-US), полное изображение + нижние 35% (там MRZ)
    /// + те же проходы для перевёрнутого изображения (.down), на случай «вверх ногами».
    static func mrzCandidateLines(_ image: UIImage) async -> [String] {
        guard let cg = image.cgImage else { return [] }
        let bottom = CGRect(x: 0, y: 0, width: 1, height: 0.35)
        var lines: [String] = []
        lines += await recognizeLines(cg: cg, orientation: .up, languages: ["en-US"], roi: nil)
        lines += await recognizeLines(cg: cg, orientation: .up, languages: ["en-US"], roi: bottom)
        lines += await recognizeLines(cg: cg, orientation: .down, languages: ["en-US"], roi: nil)
        lines += await recognizeLines(cg: cg, orientation: .down, languages: ["en-US"], roi: bottom)
        return lines
    }

    /// Общий текст (ru + en) — для показа пользователю, если MRZ не распозналась.
    static func recognizeText(_ image: UIImage) async -> String {
        guard let cg = image.cgImage else { return "" }
        let lines = await recognizeLines(cg: cg, orientation: .up, languages: ["ru-RU", "en-US"], roi: nil)
        return lines.joined(separator: "\n")
    }
}
