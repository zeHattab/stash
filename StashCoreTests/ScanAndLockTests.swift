import XCTest
@testable import StashCore

// MARK: - Модель состояния сканера (без UI)

final class DocumentScanFlowTests: XCTestCase {

    func testHappyPath_openScanCaptureRecognize() {
        var flow = DocumentScanFlow()
        XCTAssertEqual(flow.state, .idle)
        flow.send(.tapScan(.ready))
        XCTAssertEqual(flow.state, .scanning)
        XCTAssertTrue(flow.presentsCamera)
        flow.send(.captured(pages: 2))
        XCTAssertEqual(flow.state, .processing(pages: 2))
        XCTAssertFalse(flow.presentsCamera)
        flow.send(.recognized(mrzFilled: true))
        XCTAssertEqual(flow.state, .finished(pages: 2, mrzFilled: true))
    }

    func testCancelFromScanning() {
        var flow = DocumentScanFlow()
        flow.send(.tapScan(.ready))
        flow.send(.cancelled)
        XCTAssertEqual(flow.state, .cancelled)
    }

    func testCapturedZeroPagesIsCancel() {
        var flow = DocumentScanFlow()
        flow.send(.tapScan(.ready))
        flow.send(.captured(pages: 0))
        XCTAssertEqual(flow.state, .cancelled)
    }

    func testFailureFromScanning() {
        var flow = DocumentScanFlow()
        flow.send(.tapScan(.ready))
        flow.send(.failed)
        XCTAssertEqual(flow.state, .failed)
    }

    func testPermissionGrantedLeadsToScanning() {
        var flow = DocumentScanFlow()
        flow.send(.tapScan(.needsPermission))
        XCTAssertEqual(flow.state, .requestingPermission)
        XCTAssertFalse(flow.presentsCamera)
        flow.send(.permissionResolved(granted: true))
        XCTAssertEqual(flow.state, .scanning)
    }

    func testPermissionDeniedBlocks() {
        var flow = DocumentScanFlow()
        flow.send(.tapScan(.needsPermission))
        flow.send(.permissionResolved(granted: false))
        XCTAssertEqual(flow.state, .blocked(.denied))
    }

    func testDeniedAndUnsupportedBlockImmediately() {
        var denied = DocumentScanFlow()
        denied.send(.tapScan(.denied))
        XCTAssertEqual(denied.state, .blocked(.denied))

        var unsupported = DocumentScanFlow()
        unsupported.send(.tapScan(.unsupported))
        XCTAssertEqual(unsupported.state, .blocked(.unsupported))
    }

    func testNoSilentCameraFromBlockedOrIdle() {
        // Камера показывается ТОЛЬКО из .scanning — молчаливого открытия нет.
        var flow = DocumentScanFlow()
        XCTAssertFalse(flow.presentsCamera)
        flow.send(.tapScan(.denied))
        XCTAssertFalse(flow.presentsCamera)
        flow.send(.captured(pages: 1)) // недопустимо из blocked — игнор
        XCTAssertEqual(flow.state, .blocked(.denied))
    }

    func testResetReturnsToIdle() {
        var flow = DocumentScanFlow()
        flow.send(.tapScan(.ready))
        flow.send(.captured(pages: 1))
        flow.send(.reset)
        XCTAssertEqual(flow.state, .idle)
    }
}

// MARK: - Автоблокировка и свой системный экран

@MainActor
final class SystemScreenLockTests: XCTestCase {

    private func makeModel() -> (AppModel, TestClock) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("stash-lock-tests-\(UUID().uuidString)", isDirectory: true)
        let url = dir.appendingPathComponent("vault.stash")
        let store = VaultStore(configuration: .init(fileURL: url, kdfIterations: 1_000))
        let clock = TestClock()
        let model = AppModel(
            store: store,
            biometrics: MockBiometrics(type: .faceID, available: true),
            keychain: MockKeychain(),
            settings: MockSettings(),
            now: { clock.now }
        )
        return (model, clock)
    }

    func testImmediateTimeoutLocksOnBackgroundWithoutSystemScreen() async throws {
        let (model, clock) = makeModel()
        try await model.createVault(masterPassword: "correct horse battery staple 42")
        model.setAutoLockTimeout(.immediately)
        await model.didEnterBackground(at: clock.now)
        XCTAssertEqual(model.phase, .locked)
    }

    func testSystemScreenSuppressesImmediateBackgroundLock() async throws {
        let (model, clock) = makeModel()
        try await model.createVault(masterPassword: "correct horse battery staple 42")
        model.setAutoLockTimeout(.immediately)
        model.beginSystemScreen()                       // открыт наш экран (камера/пикер)
        await model.didEnterBackground(at: clock.now)
        XCTAssertEqual(model.phase, .unlocked, "свой системный экран не должен блокировать даже при «Сразу»")
        model.endSystemScreen()
    }

    func testSystemScreenSuppressesTimedForegroundLock() async throws {
        let (model, clock) = makeModel()
        try await model.createVault(masterPassword: "correct horse battery staple 42")
        model.setAutoLockTimeout(.oneMinute)
        model.beginSystemScreen()
        await model.didEnterBackground(at: clock.now)
        await model.willEnterForeground(at: clock.now.addingTimeInterval(120))
        XCTAssertEqual(model.phase, .unlocked)
        model.endSystemScreen()
    }

    func testTimedLockStillWorksWithoutSystemScreen() async throws {
        let (model, clock) = makeModel()
        try await model.createVault(masterPassword: "correct horse battery staple 42")
        model.setAutoLockTimeout(.oneMinute)
        await model.didEnterBackground(at: clock.now)
        await model.willEnterForeground(at: clock.now.addingTimeInterval(61))
        XCTAssertEqual(model.phase, .locked)
    }

    func testDeviceLockAlwaysLocksEvenWithSystemScreen() async throws {
        let (model, _) = makeModel()
        try await model.createVault(masterPassword: "correct horse battery staple 42")
        model.beginSystemScreen()
        await model.deviceDidLock()
        XCTAssertEqual(model.phase, .locked, "блокировка самого iPhone работает всегда")
    }

    func testNestedSystemScreenDepth() {
        let (model, _) = makeModel()
        model.beginSystemScreen()
        model.beginSystemScreen()
        model.endSystemScreen()
        XCTAssertTrue(model.presentingSystemScreen)
        model.endSystemScreen()
        XCTAssertFalse(model.presentingSystemScreen)
    }
}

// MARK: - Уведомления по сейфу (привязка к тегу)

final class ExpiryNotificationPlanTests: XCTestCase {

    private var utcCal: Calendar {
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c
    }

    func testRemovesOnlyOwnVaultIdentifiers() {
        let a = ExpiryNotificationPlan.prefix(tag: "aaaa") + "123"
        let b = ExpiryNotificationPlan.prefix(tag: "bbbb") + "456"
        let foreign = "someone.else.789"
        let toRemove = ExpiryNotificationPlan.identifiersToRemove(
            existing: [a, b, foreign], tag: "aaaa")
        XCTAssertEqual(toRemove, [a])
        XCTAssertFalse(toRemove.contains(b))
        XCTAssertFalse(toRemove.contains(foreign))
    }

    func testRequestsAreFutureDedupedAndTagged() {
        let cal = utcCal
        let now = cal.date(from: DateComponents(year: 2026, month: 1, day: 1))!
        let expiry = cal.date(from: DateComponents(year: 2026, month: 6, day: 1))! // +151 дн
        let reqs = ExpiryNotificationPlan.requests(
            expiryDates: [expiry], tag: "aaaa", now: now, calendar: cal)
        // leads 90/30/7 от 1 июня — все в будущем относительно 1 янв
        XCTAssertEqual(reqs.count, 3)
        XCTAssertTrue(reqs.allSatisfy { $0.identifier.hasPrefix(ExpiryNotificationPlan.prefix(tag: "aaaa")) })
        // отсортированы по возрастанию дня
        XCTAssertTrue(reqs[0].month <= reqs[1].month)
    }

    func testPastLeadsAreSkipped() {
        let cal = utcCal
        let now = cal.date(from: DateComponents(year: 2026, month: 5, day: 28))!
        let expiry = cal.date(from: DateComponents(year: 2026, month: 6, day: 1))! // через 4 дня
        let reqs = ExpiryNotificationPlan.requests(
            expiryDates: [expiry], tag: "t", now: now, calendar: cal)
        // 90 и 30 дней назад — в прошлом; 7 дней до = 25 мая — тоже прошлое → пусто
        XCTAssertTrue(reqs.isEmpty)
    }
}
