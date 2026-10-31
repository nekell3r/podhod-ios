import XCTest

@MainActor
final class BodyProgressUITests: XCTestCase {
    func testMeasurements() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(ru)", "-AppleLocale", "ru_RU"]
        app.launch()
        defer { app.terminate() }
        app.buttons["Прогресс"].tap()
        let open = app.buttons["body.open"]
        XCTAssertTrue(open.waitForExistence(timeout: 5))
        open.tap()
        app.buttons["body.measure.add"].tap()
        let weight = app.textFields["body.metric.weight"]
        XCTAssertTrue(weight.waitForExistence(timeout: 5))
        weight.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        weight.typeText("75,5")
        app.textFields["body.metric.waist"].coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        app.textFields["body.metric.waist"].typeText("80")
        app.buttons["body.keyboard.done"].tap()
        app.navigationBars["Новые замеры"].buttons["Сохранить"].tap()
        XCTAssertTrue(app.buttons["body.chart.metric"].waitForExistence(timeout: 5))
        capture("ios08-measurements", app: app)
    }

    func testPrivatePhotoImports() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(ru)", "-AppleLocale", "ru_RU"]
        app.launch()
        defer { app.terminate() }
        app.buttons["Прогресс"].tap()
        let open = app.buttons["body.open"]
        XCTAssertTrue(open.waitForExistence(timeout: 5))
        open.tap()
        app.buttons["Фото"].tap()
        addPhoto(in: app, index: 0, side: false)
        addPhoto(in: app, index: 1, side: true)
        capture("ios08-gallery", app: app)
    }

    func testPrivatePhotoComparison() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(ru)", "-AppleLocale", "ru_RU"]
        app.launch()
        defer { app.terminate() }
        app.buttons["Прогресс"].tap()
        let open = app.buttons["body.open"]
        XCTAssertTrue(open.waitForExistence(timeout: 5))
        open.tap()
        app.buttons["Фото"].tap()
        app.buttons["Сравнить два фото"].tap()
        let first = app.buttons["body.compare.first"]
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        first.tap()
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "снимок 1")).firstMatch.tap()
        app.buttons["body.compare.second"].tap()
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "снимок 2")).firstMatch.tap()
        expectation(for: NSPredicate(format: "count == 2"),
            evaluatedWith: app.otherElements["body.photo.comparison"].images.matching(identifier: "Личное фото прогресса"))
        waitForExpectations(timeout: 10)
        capture("ios08-photo-comparison", app: app)
        app.navigationBars["Сравнение фото"].buttons["Готово"].tap()
        let photo = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Фото ")).firstMatch
        XCTAssertTrue(photo.waitForExistence(timeout: 5))
        photo.tap()
        app.buttons["Удалить копию фото"].tap()
        app.buttons["Удалить фото"].tap()
        XCTAssertTrue(app.buttons["Сравнить два фото"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Сравнить два фото"].isEnabled)
        capture("ios08-photo-deleted", app: app)
    }

    private func addPhoto(in app: XCUIApplication, index: Int, side: Bool) {
        app.buttons["Добавить фото за дату"].tap()
        XCTAssertTrue(app.navigationBars["Новое фото"].waitForExistence(timeout: 5))
        if side {
            app.buttons["body.photo.angle"].tap()
            app.buttons["Сбоку"].tap()
        }
        app.buttons["Выбрать фото"].tap()
        let images = app.images.matching(identifier: "PXGGridLayout-Info")
        XCTAssertTrue(images.firstMatch.waitForExistence(timeout: 15))
        capture("ios08-system-picker", app: app)
        let photos = images.allElementsBoundByIndex.filter { app.frame.contains($0.frame) && $0.frame.width > 60 }
        XCTAssertGreaterThan(photos.count, index)
        photos[index].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let save = app.buttons["Сохранить фото"]
        XCTAssertTrue(save.waitForExistence(timeout: 10))
        let enabled = NSPredicate(format: "enabled == true")
        expectation(for: enabled, evaluatedWith: save)
        waitForExpectations(timeout: 15)
        capture("ios08-private-photo-preview-\(index)", app: app)
        save.tap()
        XCTAssertTrue(app.buttons["Добавить фото за дату"].waitForExistence(timeout: 5))
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
