import SwiftUI
import VisionKit
import Vision
import ImageIO
import StashCore
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
    /// Наблюдения одного прохода: текст + bounding box (нормализованные координаты Vision,
    /// начало в левом НИЖНЕМ углу). ROI ограничивает поиск, координаты — относительно всего кадра.
    private static func observations(cg: CGImage, orientation: CGImagePropertyOrientation,
                                     languages: [String], roi: CGRect?) async -> [MRZFragment] {
        await Task.detached(priority: .userInitiated) { () -> [MRZFragment] in
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false
            request.recognitionLanguages = languages
            if let roi { request.regionOfInterest = roi }
            let handler = VNImageRequestHandler(cgImage: cg, orientation: orientation, options: [:])
            try? handler.perform([request])
            let results = request.results ?? []
            return results.compactMap { obs -> MRZFragment? in
                guard let s = obs.topCandidates(1).first?.string else { return nil }
                let bb = obs.boundingBox
                return MRZFragment(text: s, minX: bb.minX, maxX: bb.maxX, minY: bb.minY, maxY: bb.maxY)
            }
        }.value
    }

    /// Ряды-кандидаты MRZ (куски каждой строки), СКЛЕЕННЫЕ по геометрии. Латиница (en-US),
    /// полный кадр и нижние 40% + то же для перевёрнутого (.down), на случай «вверх ногами».
    /// Склейка — в каждом проходе отдельно (координаты .up и .down не смешиваем).
    static func mrzAssembledRows(_ image: UIImage) async -> (rows: [[String]], joins: Int) {
        guard let cg = image.cgImage else { return ([], 0) }
        let bottom = CGRect(x: 0, y: 0, width: 1, height: 0.40)
        let passes: [(CGImagePropertyOrientation, CGRect?)] = [
            (.up, nil), (.up, bottom), (.down, nil), (.down, bottom),
        ]
        var rows: [[String]] = []
        var joins = 0
        for (orient, roi) in passes {
            let frags = await observations(cg: cg, orientation: orient, languages: ["en-US"], roi: roi)
            let asm = MRZLineAssembler.assemble(frags)
            rows += asm.rows
            joins += asm.joins
        }
        return (rows, joins)
    }

    /// Общий текст (ru + en) — для показа пользователю, если MRZ не распозналась.
    static func recognizeText(_ image: UIImage) async -> String {
        guard let cg = image.cgImage else { return "" }
        let frags = await observations(cg: cg, orientation: .up, languages: ["ru-RU", "en-US"], roi: nil)
        return frags.map(\.text).joined(separator: "\n")
    }
}
