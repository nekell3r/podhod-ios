import XCTest

@MainActor
final class WorkoutRestUITests: XCTestCase {
    func testRestoredLockScreenPresentation() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(ru)", "-AppleLocale", "ru_RU"]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["Продолжить тренировку"].waitForExistence(timeout: 5))
        XCUIDevice.shared.press(.home)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.015)).press(forDuration: 0.1,
            thenDragTo: springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.7)))
        let timer = springboard.staticTexts["Осталось отдыха"].firstMatch
        XCTAssertTrue(timer.waitForExistence(timeout: 5))
        XCTAssertTrue(springboard.frame.contains(timer.frame))
        XCTAssertTrue(springboard.staticTexts["Между подходами"].exists)
        capture("ios09-lock-screen", app: springboard)
        XCUIDevice.shared.press(.home)
        springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.035)).press(forDuration: 1)
        let stop = springboard.descendants(matching: .any).matching(identifier: "Закончить отдых в Подходе").firstMatch
        XCTAssertTrue(stop.waitForExistence(timeout: 5))
        capture("ios09-island-expanded", app: springboard)
        stop.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 5))
    }

    func testIslandTimerAndStopLink() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(ru)", "-AppleLocale", "ru_RU"]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["Продолжить тренировку"].waitForExistence(timeout: 5))
        app.buttons["Продолжить тренировку"].tap()
        app.buttons["Следующее упражнение"].tap()
        reveal(app.buttons["Записать подход 2"], in: app)
        app.buttons["Записать подход 2"].tap()
        XCTAssertTrue(app.buttons["Закончить отдых"].waitForExistence(timeout: 5))
        XCUIDevice.shared.press(.home)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.035)).press(forDuration: 1)
        let timer = springboard.staticTexts["Осталось отдыха"].firstMatch
        XCTAssertTrue(timer.waitForExistence(timeout: 5))
        XCTAssertGreaterThan(timer.frame.width, 0)
        XCTAssertLessThan(timer.frame.width, 100)
        XCTAssertGreaterThan(timer.frame.height, 0)
        XCTAssertLessThan(timer.frame.height, 80)
        XCTAssertTrue(springboard.frame.contains(timer.frame))
        let stop = springboard.descendants(matching: .any).matching(identifier: "Закончить отдых в Подходе").firstMatch
        XCTAssertTrue(stop.waitForExistence(timeout: 5))
        capture("ios09-island-expanded", app: springboard)
        stop.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 5))
        XCTAssertFalse(app.buttons["Закончить отдых"].exists)
        capture("ios09-stopped-from-island", app: app)
    }

    func testLiveActivityControlsAndBackgroundNotification() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(ru)", "-AppleLocale", "ru_RU"]
        app.launch()
        defer { app.terminate() }
        let resume = app.buttons["Продолжить тренировку"]
        XCTAssertTrue(resume.waitForExistence(timeout: 5))
        resume.tap()
        app.buttons["Действия тренировки"].tap()
        app.buttons["Настроить отдых"].tap()
        XCTAssertTrue(app.buttons["rest.notification.enable"].waitForExistence(timeout: 5))
        app.buttons["rest.notification.enable"].tap()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allow = springboard.alerts.buttons.matching(NSPredicate(format: "label IN %@", ["Разрешить", "Allow"])).firstMatch
        if allow.waitForExistence(timeout: 3) { allow.tap() }
        XCTAssertTrue(app.buttons["Выключить уведомление отдыха"].waitForExistence(timeout: 5))
        capture("ios09-rest-settings", app: app)
        app.navigationBars["Отдых"].buttons["Сохранить"].tap()
        reveal(app.buttons["Записать подход 2"], in: app)
        app.buttons["Записать подход 2"].tap()
        XCTAssertTrue(app.buttons["Закончить отдых"].waitForExistence(timeout: 5))
        capture("ios09-active-rest", app: app)
        XCUIDevice.shared.press(.home)
        springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.035)).press(forDuration: 1)
        capture("ios09-island-expanded", app: springboard)
        let extend = springboard.descendants(matching: .any).matching(identifier: "Добавить 30 секунд отдыха в Подходе").firstMatch
        XCTAssertTrue(extend.waitForExistence(timeout: 5))
        extend.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 5))
        XCTAssertTrue(app.buttons["Закончить отдых"].waitForExistence(timeout: 5))
        capture("ios09-extended-rest", app: app)
        app.buttons["Закончить отдых"].tap()
        XCTAssertFalse(app.buttons["Закончить отдых"].exists)
        reveal(app.buttons["Записать подход 3"], in: app)
        app.buttons["Записать подход 3"].tap()
        XCTAssertTrue(app.buttons["Закончить отдых"].waitForExistence(timeout: 5))
        XCUIDevice.shared.press(.home)
        let notification = springboard.staticTexts["Отдых окончен"].firstMatch
        XCTAssertTrue(notification.waitForExistence(timeout: 25))
        capture("ios09-background-notification", app: springboard)
        notification.tap()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 5))
        XCTAssertTrue(app.buttons["Закончить отдых"].waitForExistence(timeout: 5))
        capture("ios09-expired-rest", app: app)
        app.buttons["Закончить отдых"].tap()
    }

    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<8 where !element.isHittable {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.68)).press(forDuration: 0.1,
                thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25)))
        }
    }

    private func capture(_ name: String, app: XCUIApplication) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
        let tree = XCTAttachment(string: app.debugDescription)
        tree.name = name + "-accessibility"
        tree.lifetime = .keepAlways
        add(tree)
    }
}
