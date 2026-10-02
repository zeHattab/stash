import Foundation

/// Техническая диагностика последнего скана для скрытого экрана отладки.
/// СТРОГО без текста и данных документа — только размеры/признаки.
public struct ScanDiagnostics: Sendable, Equatable {
    public var imageWidth: Int
    public var imageHeight: Int
    public var orientationRaw: Int
    public var recognizedLineCount: Int
    public var mrzCandidateCount: Int
    public var detectedFormat: String?
    public var failedChecks: [String]
    public var recovered: Bool
    public init(imageWidth: Int, imageHeight: Int, orientationRaw: Int,
                recognizedLineCount: Int, mrzCandidateCount: Int,
                detectedFormat: String?, failedChecks: [String], recovered: Bool) {
        self.imageWidth = imageWidth; self.imageHeight = imageHeight
        self.orientationRaw = orientationRaw; self.recognizedLineCount = recognizedLineCount
        self.mrzCandidateCount = mrzCandidateCount; self.detectedFormat = detectedFormat
        self.failedChecks = failedChecks; self.recovered = recovered
    }
}

/// Доступность сканера (результат предпроверки камеры в UI).
public enum ScanAvailability: Equatable, Sendable {
    case ready            // камера разрешена и поддерживается
    case needsPermission  // доступ ещё не запрашивался (.notDetermined)
    case denied           // доступ запрещён/ограничён — нужен экран «Настройки»
    case unsupported      // VNDocumentCameraViewController.isSupported == false
}

/// Чистая модель состояния сканирования — тестируется без UI.
/// Экран камеры открывается ТОЛЬКО из состояния `.scanning`; молчаливого закрытия нет:
/// недоступность всегда переводит во `.blocked`, чтобы UI показал причину.
public struct DocumentScanFlow: Equatable, Sendable {

    public enum State: Equatable, Sendable {
        case idle
        case requestingPermission
        case scanning
        case processing(pages: Int)
        case finished(pages: Int, mrzFilled: Bool)
        case cancelled
        case failed
        case blocked(ScanAvailability)
    }

    public enum Event: Equatable, Sendable {
        case tapScan(ScanAvailability)
        case permissionResolved(granted: Bool)
        case captured(pages: Int)
        case recognized(mrzFilled: Bool)
        case cancelled
        case failed
        case reset
    }

    public private(set) var state: State = .idle

    public init() {}

    /// true, пока должен быть показан нативный экран камеры.
    public var presentsCamera: Bool { state == .scanning }

    public mutating func send(_ event: Event) {
        switch (state, event) {
        case (.idle, .tapScan(.ready)):
            state = .scanning
        case (.idle, .tapScan(.needsPermission)):
            state = .requestingPermission
        case (.idle, .tapScan(.denied)):
            state = .blocked(.denied)
        case (.idle, .tapScan(.unsupported)):
            state = .blocked(.unsupported)

        case (.requestingPermission, .permissionResolved(true)):
            state = .scanning
        case (.requestingPermission, .permissionResolved(false)):
            state = .blocked(.denied)

        case let (.scanning, .captured(pages)) where pages > 0:
            state = .processing(pages: pages)
        case (.scanning, .captured):          // ноль страниц = отмена
            state = .cancelled
        case (.scanning, .cancelled):
            state = .cancelled
        case (.scanning, .failed):
            state = .failed

        case let (.processing(pages), .recognized(mrzFilled)):
            state = .finished(pages: pages, mrzFilled: mrzFilled)

        case (_, .reset):
            state = .idle

        default:
            break // недопустимый переход игнорируем — состояние стабильно
        }
    }
}
