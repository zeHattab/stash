import XCTest
@testable import StashCore

final class StashCoreTests: XCTestCase {

    /// Заглушка-тест первого захода: подтверждает, что модуль StashCore
    /// собирается, импортируется и экспортирует ожидаемый символ.
    func testCoreVersionIsNotEmpty() {
        XCTAssertFalse(StashCoreInfo.version.isEmpty)
    }
}
