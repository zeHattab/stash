import XCTest
@testable import StashCore

@MainActor
final class AppModelTests: XCTestCase {

    private let masterPassword = "correct horse battery staple 42"

    private func makeModel(
        available: Bool = true,
        type: BiometryKind = .faceID
    ) -> (AppModel, MockKeychain, MockSettings, TestClock) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("stash-app-tests-\(UUID().uuidString)", isDirectory: true)
        let url = dir.appendingPathComponent("vault.stash")
        let store = VaultStore(configuration: .init(fileURL: url, kdfIterations: 1_000))
        let keychain = MockKeychain()
        let settings = MockSettings()
        let clock = TestClock()
        let model = AppModel(
            store: store,
            biometrics: MockBiometrics(type: type, available: available),
            keychain: keychain,
            settings: settings,
            now: { clock.now }
        )
        return (model, keychain, settings, clock)
    }

    func testStartOnboardingThenCreateUnlocks() async throws {
        let (model, _, _, _) = makeModel()
        await model.start()
        XCTAssertEqual(model.phase, .onboarding)
        try await model.createVault(masterPassword: masterPassword)
        XCTAssertEqual(model.phase, .unlocked)
    }

    func testLockThenUnlockWithPassword() async throws {
        let (model, _, _, _) = makeModel()
        try await model.createVault(masterPassword: masterPassword)
        await model.lock()
        XCTAssertEqual(model.phase, .locked)
        try await model.unlockWithPassword(masterPassword)
        XCTAssertEqual(model.phase, .unlocked)
    }

    func testWrongPasswordLockoutAndRecovery() async throws {
        let (model, _, _, clock) = makeModel()
        try await model.createVault(masterPassword: masterPassword)
        await model.lock()

        for _ in 0..<5 {
            do {
                try await model.unlockWithPassword("wrong-pass")
                XCTFail("ожидался неверный пароль")
            } catch let error as VaultError {
                XCTAssertEqual(error, .wrongPassword)
            }
        }
        XCTAssertEqual(model.failedAttempts, 5)
        XCTAssertNotNil(model.lockedOutUntil)

        // Даже верный пароль заблокирован паузой.
        do {
            try await model.unlockWithPassword(masterPassword)
            XCTFail("ожидалась пауза")
        } catch let AppModelError.lockedOut(remaining) {
            XCTAssertGreaterThan(remaining, 0)
        }

        // Переждали паузу — верный пароль открывает.
        clock.now = clock.now.addingTimeInterval(31)
        try await model.unlockWithPassword(masterPassword)
        XCTAssertEqual(model.phase, .unlocked)
        XCTAssertEqual(model.failedAttempts, 0)
    }

    func testEnableBiometricsThenUnlock() async throws {
        let (model, keychain, _, _) = makeModel(available: true)
        try await model.createVault(masterPassword: masterPassword)
        try await model.enableBiometrics()
        XCTAssertTrue(model.isBiometricEnabled)
        XCTAssertNotNil(keychain.stored)

        await model.lock()
        try await model.unlockWithBiometrics()
        XCTAssertEqual(model.phase, .unlocked)
    }

    func testBiometricKeyLostFallsBackToPassword() async throws {
        let (model, keychain, _, _) = makeModel(available: true)
        try await model.createVault(masterPassword: masterPassword)
        try await model.enableBiometrics()
        await model.lock()

        keychain.simulateMissing = true
        do {
            try await model.unlockWithBiometrics()
            XCTFail("ожидалось отсутствие ключа")
        } catch {
            // ожидаемо
        }
        XCTAssertFalse(model.isBiometricEnabled)
        XCTAssertEqual(model.phase, .locked)

        try await model.unlockWithPassword(masterPassword)
        XCTAssertEqual(model.phase, .unlocked)
    }

    func testAutoLockAfterTimeout() async throws {
        let (model, _, _, clock) = makeModel()
        try await model.createVault(masterPassword: masterPassword)
        model.setAutoLockTimeout(.oneMinute)

        await model.didEnterBackground(at: clock.now)
        await model.willEnterForeground(at: clock.now.addingTimeInterval(61))
        XCTAssertEqual(model.phase, .locked)
    }

    func testAutoLockKeepsUnlockedBeforeTimeout() async throws {
        let (model, _, _, clock) = makeModel()
        try await model.createVault(masterPassword: masterPassword)
        model.setAutoLockTimeout(.fiveMinutes)

        await model.didEnterBackground(at: clock.now)
        await model.willEnterForeground(at: clock.now.addingTimeInterval(60))
        XCTAssertEqual(model.phase, .unlocked)
    }

    func testImmediateAutoLock() async throws {
        let (model, _, _, clock) = makeModel()
        try await model.createVault(masterPassword: masterPassword)
        model.setAutoLockTimeout(.immediately)

        await model.didEnterBackground(at: clock.now)
        XCTAssertEqual(model.phase, .locked)
    }

    func testChangeMasterPasswordKeepsBiometrics() async throws {
        let (model, keychain, _, _) = makeModel(available: true)
        try await model.createVault(masterPassword: masterPassword)
        try await model.enableBiometrics()
        let newPassword = "another strong passphrase 99"
        try await model.changeMasterPassword(old: masterPassword, new: newPassword)
        XCTAssertNotNil(keychain.stored)

        await model.lock()
        try await model.unlockWithPassword(newPassword)
        XCTAssertEqual(model.phase, .unlocked)
    }
}
