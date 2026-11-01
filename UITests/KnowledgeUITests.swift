import XCTest

@MainActor
final class KnowledgeUITests: XCTestCase {
    func testSearchSourcesAndSavedTechniqueSurviveRestart() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(ru)", "-AppleLocale", "ru_RU"]
        app.launch()
        defer { app.terminate() }
        app.buttons["Программа"].tap()
        app.buttons["knowledge.open"].tap()
        XCTAssertTrue(app.navigationBars["База знаний"].waitForExistence(timeout: 5))
        capture("ios10-library", app: app)
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("запас")
        let article = app.descendants(matching: .any).matching(identifier: "knowledge.article.repetitions-in-reserve").firstMatch
        XCTAssertTrue(article.waitForExistence(timeout: 5))
        article.tap()
        app.buttons["knowledge.article.save"].tap()
        XCTAssertEqual(app.buttons["knowledge.article.save"].label, "Убрать материал из сохранённого")
        capture("ios10-article", app: app)
        let source = app.staticTexts["Michael C. Zourdos и соавторы, 2016"]
        reveal(source, in: app)
        XCTAssertTrue(source.isHittable)
        capture("ios10-article-source", app: app)
        app.navigationBars["Материал"].buttons.element(boundBy: 0).tap()
        app.buttons["Техника"].tap()
        search.tap()
        search.buttons.firstMatch.tap()
        search.typeText("жим")
        let bench = app.buttons["knowledge.exercise.00000000-0000-4000-8000-000000000001"]
        XCTAssertTrue(bench.waitForExistence(timeout: 5))
        bench.tap()
        XCTAssertTrue(app.navigationBars["Об упражнении"].waitForExistence(timeout: 5))
        app.buttons["knowledge.exercise.save"].tap()
        XCTAssertEqual(app.buttons["knowledge.exercise.save"].label, "Убрать технику из сохранённого")
        capture("ios10-technique", app: app)
        let attribution = app.staticTexts["Данные справочника: sistab2"]
        reveal(attribution, in: app)
        XCTAssertTrue(attribution.isHittable)
        capture("ios10-technique-source", app: app)
        app.navigationBars["Об упражнении"].buttons["Закрыть"].tap()
        search.tap()
        search.buttons.firstMatch.tap()
        app.buttons["Сохранённое"].tap()
        XCTAssertTrue(article.waitForExistence(timeout: 5))
        XCTAssertTrue(bench.exists)
        capture("ios10-saved", app: app)
        app.terminate()
        app.launch()
        app.buttons["Программа"].tap()
        app.buttons["knowledge.open"].tap()
        app.buttons["Сохранённое"].tap()
        XCTAssertTrue(article.waitForExistence(timeout: 5))
        XCTAssertTrue(bench.exists)
    }

    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<10 where !element.isHittable {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7)).press(forDuration: 0.1,
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
