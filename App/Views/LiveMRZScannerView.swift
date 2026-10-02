import SwiftUI
import VisionKit
import AVFoundation
import StashCore

/// Живое считывание MRZ камерой: распознаёт две нижние строки в рамке, каждый «кадр»
/// собирает строки и проверяет контрольные цифры; при полном совпадении — вибрация и
/// заполнение. Кадры нигде не сохраняются. Возвращает MRZResult или nil (отмена/таймаут).
struct LiveMRZScannerView: UIViewControllerRepresentable {
    let prefer: MRZResult.Format?
    var onComplete: (MRZResult?) -> Void

    static var isSupported: Bool {
        DataScannerViewController.isSupported && DataScannerViewController.isAvailable
    }

    func makeUIViewController(context: Context) -> LiveMRZContainer {
        LiveMRZContainer(prefer: prefer, onComplete: onComplete)
    }
    func updateUIViewController(_ controller: LiveMRZContainer, context: Context) {}
}

final class LiveMRZContainer: UIViewController {
    private let prefer: MRZResult.Format?
    private let onComplete: (MRZResult?) -> Void
    private let scanner = DataScannerViewController(
        recognizedDataTypes: [.text(languages: ["en-US"])],
        qualityLevel: .accurate,
        recognizesMultipleItems: true,
        isHighFrameRateTrackingEnabled: true,
        isHighlightingEnabled: false)

    private var rowBuffer: [[String]] = []
    private var lineHistory: [String] = []
    private var finished = false
    private var lastProcess = Date.distantPast
    private let bandFraction: CGFloat = 0.22
    private let bandView = UIView()
    private var timeoutWork: DispatchWorkItem?

    init(prefer: MRZResult.Format?, onComplete: @escaping (MRZResult?) -> Void) {
        self.prefer = prefer
        self.onComplete = onComplete
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        scanner.delegate = self
        addChild(scanner)
        scanner.view.frame = view.bounds
        scanner.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(scanner.view)
        scanner.didMove(toParent: self)

        setupOverlay()
        try? scanner.startScanning()

        let work = DispatchWorkItem { [weak self] in self?.timeout() }
        timeoutWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: work)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let h = view.bounds.height * bandFraction
        let rect = CGRect(x: 16, y: view.bounds.midY - h / 2, width: view.bounds.width - 32, height: h)
        bandView.frame = rect
        scanner.regionOfInterest = rect
    }

    private func setupOverlay() {
        bandView.layer.borderColor = UIColor.white.cgColor
        bandView.layer.borderWidth = 2
        bandView.layer.cornerRadius = 8
        bandView.isUserInteractionEnabled = false
        view.addSubview(bandView)

        let hint = UILabel()
        hint.text = String(localized: "Наведите на две нижние строки паспорта")
        hint.textColor = .white
        hint.font = .preferredFont(forTextStyle: .headline)
        hint.numberOfLines = 0
        hint.textAlignment = .center
        hint.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(hint)

        let cancel = UIButton(type: .system)
        cancel.setTitle(String(localized: "Отмена"), for: .normal)
        cancel.tintColor = .white
        cancel.addTarget(self, action: #selector(cancelTapped), for: .touchUpInside)
        cancel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(cancel)

        let torch = UIButton(type: .system)
        torch.setImage(UIImage(systemName: "flashlight.off.fill"), for: .normal)
        torch.tintColor = .white
        torch.addTarget(self, action: #selector(toggleTorch), for: .touchUpInside)
        torch.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(torch)

        NSLayoutConstraint.activate([
            hint.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            hint.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            hint.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 24),
            cancel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            cancel.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -24),
            torch.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            torch.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -24),
        ])
    }

    @objc private func cancelTapped() { finish(nil) }

    @objc private func toggleTorch() {
        guard let device = AVCaptureDevice.default(for: .video), device.hasTorch else { return }
        try? device.lockForConfiguration()
        device.torchMode = (device.torchMode == .on) ? .off : .on
        device.unlockForConfiguration()
    }

    private func timeout() { if !finished { finish(nil) } }

    private func finish(_ result: MRZResult?) {
        guard !finished else { return }
        finished = true
        timeoutWork?.cancel()
        scanner.stopScanning()
        if result != nil { UINotificationFeedbackGenerator().notificationOccurred(.success) }
        // Погасить фонарик, если включали.
        if let device = AVCaptureDevice.default(for: .video), device.hasTorch, device.torchMode == .on {
            try? device.lockForConfiguration(); device.torchMode = .off; device.unlockForConfiguration()
        }
        onComplete(result)
    }

    private func handle(_ items: [RecognizedItem]) {
        guard !finished else { return }
        let now = Date()
        guard now.timeIntervalSince(lastProcess) > 0.25 else { return } // троттлинг
        lastProcess = now

        let b = scanner.view.bounds
        guard b.width > 0, b.height > 0 else { return }
        var frags: [MRZFragment] = []
        for item in items {
            guard case let .text(text) = item else { continue }
            let q = item.bounds
            let xs = [q.topLeft.x, q.topRight.x, q.bottomLeft.x, q.bottomRight.x]
            let ys = [q.topLeft.y, q.topRight.y, q.bottomLeft.y, q.bottomRight.y]
            let minX = Double((xs.min() ?? 0) / b.width)
            let maxX = Double((xs.max() ?? 0) / b.width)
            // координаты вида y-вниз → нормализуем в y-вверх (как ждёт сборщик)
            let minY = Double(1 - (ys.max() ?? 0) / b.height)
            let maxY = Double(1 - (ys.min() ?? 0) / b.height)
            frags.append(MRZFragment(text: text.transcript, minX: minX, maxX: maxX, minY: minY, maxY: maxY))
        }
        let asm = MRZLineAssembler.assemble(frags)
        rowBuffer.append(contentsOf: asm.rows)
        if rowBuffer.count > 40 { rowBuffer.removeFirst(rowBuffer.count - 40) }
        // История самых длинных строк кадров — для голосования по символам.
        if let longest = asm.rows.map({ MRZParser.normalizeLine($0.joined()) }).max(by: { $0.count < $1.count }),
           longest.count >= 28 {
            lineHistory.append(longest)
            if lineHistory.count > 30 { lineHistory.removeFirst(lineHistory.count - 30) }
        }

        var rows = rowBuffer
        if let voted = MRZVote.consensus(lineHistory) { rows.append([voted]) }
        let (result, _) = MRZParser.parseRecovering(rows: rows, prefer: prefer)
        if let result, result.checkDigitsValid { finish(result) }
    }
}

extension LiveMRZContainer: @preconcurrency DataScannerViewControllerDelegate {
    func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem],
                     allItems: [RecognizedItem]) {
        handle(allItems)
    }
    func dataScanner(_ dataScanner: DataScannerViewController, didUpdate updatedItems: [RecognizedItem],
                     allItems: [RecognizedItem]) {
        handle(allItems)
    }
}
