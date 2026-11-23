import XCTest

@MainActor
final class TrainingCycleUITests: XCTestCase {
    func testQuickSupersetAndRestNotifications() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(ru)", "-AppleLocale", "ru_RU"]
        app.launch()
        defer { app.terminate() }
        let resume = app.buttons["Продолжить тренировку"]
        XCTAssertTrue(resume.waitForExistence(timeout: 5))
        resume.tap()

        let quickSuperset = app.buttons["workout.superset.quick"]
        XCTAssertTrue(quickSuperset.waitForExistence(timeout: 5))
        capture("quick-superset-action", app: app)
        quickSuperset.tap()
        let partner = app.buttons["QA Тяга"]
        XCTAssertTrue(partner.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["QA Другой объём"].exists)
        partner.tap()
        XCTAssertTrue(app.staticTexts["Суперсет · круг 1"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Отдых после круга: 15 с"].exists)
        capture("quick-superset-created", app: app)

        let firstSet = app.buttons["Записать подход 1"]
        reveal(firstSet, in: app)
        firstSet.tap()
        XCTAssertTrue(app.staticTexts["QA Тяга"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Закончить отдых"].exists)
        reveal(firstSet, in: app)
        firstSet.tap()

        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allow = springboard.alerts.buttons.matching(NSPredicate(format: "label IN %@", ["Разрешить", "Allow"])).firstMatch
        if allow.waitForExistence(timeout: 3) { allow.tap() }
        let notification = springboard.staticTexts["Отдых окончен"].firstMatch
        XCTAssertTrue(notification.waitForExistence(timeout: 25))
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 5))
        capture("rest-foreground-notification", app: app)
        app.buttons["Закончить отдых"].tap()

        let secondSet = app.buttons["Записать подход 2"]
        reveal(secondSet, in: app)
        secondSet.tap()
        XCTAssertTrue(app.staticTexts["QA Тяга"].waitForExistence(timeout: 5))
        reveal(secondSet, in: app)
        secondSet.tap()
        XCTAssertTrue(app.buttons["Закончить отдых"].waitForExistence(timeout: 5))
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(notification.waitForExistence(timeout: 25))
        capture("rest-background-notification", app: springboard)
    }

    func testSupersetActionsAndSavedCycleDay() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(ru)", "-AppleLocale", "ru_RU"]
        app.launch()
        defer { app.terminate() }
        let resume = app.buttons["Продолжить тренировку"]
        XCTAssertTrue(resume.waitForExistence(timeout: 5))
        resume.tap()
        app.buttons["Действия тренировки"].tap()
        app.buttons["Состав и порядок"].tap()
        let count = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Кругов:")).firstMatch
        XCTAssertTrue(count.waitForExistence(timeout: 5))
        let initial = count.label.components(separatedBy: CharacterSet.decimalDigits.inverted).compactMap(Int.init).first!
        app.buttons["Добавить круг"].tap()
        XCTAssertFalse(app.buttons["Распустить"].exists)
        XCTAssertTrue(app.staticTexts["Кругов: \(initial + 1) · отдых 90 с"].waitForExistence(timeout: 5))
        capture("ios04-superset-actions", app: app)
        app.buttons["Распустить суперсет"].tap()
        app.buttons["Распустить"].tap()
        XCTAssertTrue(app.staticTexts["Группа закрыта · выполненные связи сохранены"].waitForExistence(timeout: 5))
        capture("ios04-superset-closed", app: app)
        app.buttons["Готово"].firstMatch.tap()
        app.buttons["Свернуть"].tap()
        app.buttons["Программа"].tap()
        app.buttons["training.cycle.open"].tap()
        let day = app.buttons["Неделя 1, Понедельник, изменить"]
        XCTAssertTrue(day.waitForExistence(timeout: 5))
        day.tap()
        app.buttons["training.context.load"].tap()
        app.buttons["Лёгкий"].tap()
        capture("ios04-cycle-day-editor", app: app)
        app.buttons["Сохранить"].tap()
        XCTAssertTrue(app.navigationBars["Цикл тренировок"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Лёгкий")).firstMatch.exists)
    }

    func testCyclePreviewAndSupersetRound() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(ru)", "-AppleLocale", "ru_RU"]
        app.launch()
        defer { app.terminate() }
        app.buttons["Программа"].tap()
        let open = app.buttons["training.cycle.open"]
        XCTAssertTrue(open.waitForExistence(timeout: 5))
        open.tap()
        app.buttons["Создать цикл"].tap()
        app.buttons["training.cycle.rule"].tap()
        app.buttons["Волна подходов"].tap()
        capture("ios04-cycle-parameters", app: app)
        reveal(app.buttons["Показать предпросмотр"], in: app)
        app.buttons["Показать предпросмотр"].tap()
        XCTAssertTrue(app.navigationBars["Проверить план"].waitForExistence(timeout: 5))
        for _ in 0..<2 { app.swipeDown() }
        capture("ios04-cycle-preview", app: app)
        reveal(app.buttons["Применить цикл"], in: app)
        app.buttons["Применить цикл"].tap()
        XCTAssertTrue(app.navigationBars["Цикл тренировок"].waitForExistence(timeout: 5))
        app.buttons["Готово"].firstMatch.tap()
        app.buttons["Сегодня"].tap()
        let resume = app.buttons["Продолжить тренировку"]
        XCTAssertTrue(resume.waitForExistence(timeout: 5))
        resume.tap()
        XCTAssertTrue(app.staticTexts["Суперсет · круг 1"].waitForExistence(timeout: 5))
        capture("ios04-superset-active", app: app)
        reveal(app.buttons["Записать подход 1"], in: app)
        app.buttons["Записать подход 1"].tap()
        XCTAssertTrue(app.staticTexts["QA Тяга"].waitForExistence(timeout: 5))
        reveal(app.buttons["Записать подход 1"], in: app)
        app.buttons["Записать подход 1"].tap()
        app.buttons["Действия тренировки"].tap()
        app.buttons["Состав и порядок"].tap()
        XCTAssertTrue(app.navigationBars["Состав тренировки"].waitForExistence(timeout: 5))
        capture("ios04-superset-composition", app: app)
        app.buttons["Добавить круг"].tap()
        app.buttons["Распустить суперсет"].tap()
        app.buttons["Распустить"].tap()
        XCTAssertTrue(app.staticTexts["Группа закрыта · выполненные связи сохранены"].waitForExistence(timeout: 5))
        capture("ios04-superset-closed", app: app)
    }

    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<12 where !element.isHittable {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.65)).press(forDuration: 0.1,
                thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25)))
        }
        XCTAssertTrue(element.isHittable)
    }

    private func capture(_ name: String, app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
