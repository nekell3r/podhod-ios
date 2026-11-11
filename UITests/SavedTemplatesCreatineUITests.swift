import XCTest

@MainActor
final class SavedTemplatesCreatineUITests: XCTestCase {
    func testDayPreviewCreatineAndTemplates() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(ru)", "-AppleLocale", "ru_RU"]
        app.launch()
        defer { app.terminate() }
        let example = app.buttons["Взять пример на 3 дня"]
        reveal(example, in: app)
        example.tap()
        let currentWeekday = (Calendar.current.component(.weekday, from: Date()) + 5) % 7 + 1
        let anotherWeekday = currentWeekday == 1 ? 3 : 1
        app.buttons["today.day.\(anotherWeekday)"].tap()
        XCTAssertFalse(app.buttons["Начать тренировку"].exists)
        XCTAssertFalse(app.buttons["Изменить тренировку"].exists)
        XCTAssertFalse(app.switches["creatine.taken"].exists)
        capture("day-preview", app: app)
        app.buttons["today.return"].tap()
        let creatine = app.switches["creatine.taken"]
        reveal(creatine, in: app)
        XCTAssertEqual(creatine.value as? String, "0")
        creatine.tap()
        XCTAssertEqual(creatine.value as? String, "1")
        capture("creatine-today", app: app)
        app.terminate()
        app.launch()
        reveal(creatine, in: app)
        XCTAssertEqual(creatine.value as? String, "1")
        creatine.tap()
        XCTAssertEqual(creatine.value as? String, "0")
        app.buttons["Программа"].tap()
        app.buttons["Шаблон недели"].tap()
        app.buttons["templates.open"].tap()
        for name in ["Основной", "Запасной"] {
            app.buttons["templates.save"].tap()
            app.alerts.textFields.firstMatch.tap()
            app.alerts.textFields.firstMatch.typeText(name)
            app.alerts.buttons["Сохранить"].tap()
        }
        XCTAssertTrue(app.staticTexts["Основной"].exists)
        XCTAssertTrue(app.staticTexts["Запасной"].exists)
        capture("saved-templates", app: app)
        app.buttons["templates.apply.Основной"].tap()
        app.buttons["Применить «Основной»"].tap()
        app.buttons["Готово"].tap()
    }

    func testRemovingAccidentalSet() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(ru)", "-AppleLocale", "ru_RU"]
        app.launch()
        defer { app.terminate() }
        let resume = app.buttons["Продолжить тренировку"]
        if resume.exists {
            resume.tap()
        } else {
            let example = app.buttons["Взять пример на 3 дня"]
            if example.exists { reveal(example, in: app); example.tap() }
            app.buttons["Программа"].tap()
            app.buttons["Шаблон недели"].tap()
            let start = app.buttons["Начать"].firstMatch
            reveal(start, in: app)
            start.tap()
        }
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "workout.set.remove."))
        let initialCount = rows.count
        XCTAssertGreaterThan(initialCount, 1)
        let add = app.buttons["Добавить подход"]
        reveal(add, in: app)
        capture("add-set-before", app: app)
        add.tap()
        let remove = app.buttons["workout.set.remove.\(initialCount + 1)"]
        reveal(remove, in: app)
        XCTAssertTrue(remove.exists)
        capture("visible-set-removal", app: app)
        remove.tap()
        app.sheets.buttons["Удалить подход \(initialCount + 1)"].tap()
        let removed = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: remove)
        wait(for: [removed], timeout: 5)
        XCTAssertEqual(rows.count, initialCount)
    }

    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<10 {
            if element.exists && element.isHittable && element.frame.minY >= 130 && element.frame.maxY < app.frame.height - 150 { break }
            if element.exists && element.frame.minY < 130 { app.swipeDown() }
            else { app.swipeUp() }
        }
        XCTAssertTrue(element.waitForExistence(timeout: 5))
        XCTAssertTrue(element.isHittable)
    }

    private func capture(_ name: String, app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
