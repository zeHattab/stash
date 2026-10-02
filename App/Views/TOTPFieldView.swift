import SwiftUI
import VisionKit
import Vision
import StashCore

/// Живой код 2FA: крупный код, круговой таймер до смены, нажатие — копировать.
/// За 5 с до смены показывает следующий код.
struct TOTPCodeView: View {
    let config: TOTPConfig
    var onCopy: (String, Int) -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let now = context.date
            let code = TOTP.code(config, at: now)
            let remaining = TOTP.secondsRemaining(config, at: now)
            let fraction = Double(remaining) / Double(config.period)
            Button {
                onCopy(code, remaining)
            } label: {
                HStack(spacing: 14) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(Self.grouped(code))
                            .font(.system(size: 34, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(.primary)
                        if remaining <= 5 {
                            HStack(spacing: 4) {
                                Text("след.")
                                Text(Self.grouped(TOTP.code(config, at: now.addingTimeInterval(Double(config.period)))))
                                    .monospacedDigit()
                            }
                            .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    ZStack {
                        Circle().stroke(Color.secondary.opacity(0.25), lineWidth: 3)
                        Circle().trim(from: 0, to: fraction)
                            .stroke(remaining <= 5 ? Color.orange : Color.accentColor,
                                    style: StrokeStyle(lineWidth: 3, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                        Text("\(remaining)").font(.caption2).monospacedDigit()
                    }
                    .frame(width: 34, height: 34)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Код двухфакторной защиты")
            .accessibilityValue(code)
            .accessibilityHint("Дважды коснитесь, чтобы скопировать")
        }
    }

    static func grouped(_ code: String) -> String {
        guard code.count == 6 || code.count == 8 else { return code }
        let mid = code.index(code.startIndex, offsetBy: code.count / 2)
        return code[code.startIndex..<mid] + " " + code[mid...]
    }
}

/// Сканер QR (VisionKit DataScanner). Возвращает первую найденную строку.
struct QRScannerView: UIViewControllerRepresentable {
    var onResult: (String?) -> Void

    static var isSupported: Bool {
        DataScannerViewController.isSupported && DataScannerViewController.isAvailable
    }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .accurate,
            isHighFrameRateTrackingEnabled: false,
            isHighlightingEnabled: true)
        scanner.delegate = context.coordinator
        return scanner
    }

    func updateUIViewController(_ controller: DataScannerViewController, context: Context) {
        try? controller.startScanning()
    }

    func makeCoordinator() -> Coordinator { Coordinator(onResult: onResult) }

    @MainActor
    final class Coordinator: NSObject, @preconcurrency DataScannerViewControllerDelegate {
        let onResult: (String?) -> Void
        private var done = false
        init(onResult: @escaping (String?) -> Void) { self.onResult = onResult }

        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem],
                         allItems: [RecognizedItem]) {
            report(addedItems)
        }

        private func report(_ items: [RecognizedItem]) {
            guard !done else { return }
            for item in items {
                if case let .barcode(barcode) = item, let value = barcode.payloadStringValue {
                    done = true
                    onResult(value)
                    return
                }
            }
        }
    }
}

/// Распознавание QR на изображении (Vision) — для выбора скриншота.
enum QRImageDecoder {
    static func decode(_ image: UIImage) async -> [String] {
        guard let cg = image.cgImage else { return [] }
        return await Task.detached(priority: .userInitiated) { () -> [String] in
            let request = VNDetectBarcodesRequest()
            request.symbologies = [.qr]
            let handler = VNImageRequestHandler(cgImage: cg, options: [:])
            try? handler.perform([request])
            let results = request.results ?? []
            return results.compactMap { $0.payloadStringValue }
        }.value
    }
}
