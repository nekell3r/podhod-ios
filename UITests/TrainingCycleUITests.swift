import XCTest

@MainActor
final class TrainingCycleUITests: XCTestCase {
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
