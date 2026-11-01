import XCTest

@MainActor
final class WorkoutReserveUITests: XCTestCase {
    func testReserveTwoPersistsAndFailureZeroIsExplicit() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(ru)", "-AppleLocale", "ru_RU"]
        app.launch()
        defer { app.terminate() }
        app.buttons["Продолжить тренировку"].tap()
        let reserve = app.buttons["Запас повторений, подход 3"]
        for _ in 0..<5 where !reserve.isHittable { app.swipeUp() }
        XCTAssertTrue(reserve.exists)
        reserve.tap()
        XCTAssertTrue(app.buttons["5+ повторов"].exists)
        app.buttons["2"].tap()
        XCTAssertEqual(reserve.value as? String, "2")
        app.terminate()
        app.launch()
        app.buttons["Продолжить тренировку"].tap()
        for _ in 0..<5 where !reserve.isHittable { app.swipeUp() }
        XCTAssertEqual(reserve.value as? String, "2")
        reserve.tap()
        app.buttons["0 — в отказ"].tap()
        app.buttons["Записать подход 3"].tap()
        XCTAssertEqual(reserve.value as? String, "0 — в отказ")
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "ios01-reserve-iphone15"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        let tree = XCTAttachment(string: app.debugDescription)
        tree.name = "ios01-reserve-iphone15-accessibility"
        tree.lifetime = .keepAlways
        add(tree)
    }
}
