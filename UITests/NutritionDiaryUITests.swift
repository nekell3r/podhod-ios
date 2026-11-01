import XCTest

@MainActor
final class NutritionDiaryUITests: XCTestCase {
    func testRecipeLibraryCombinesSourcesAndFiltersOwnRecipes() {
        let app = launchDiary()
        defer { app.terminate() }
        app.segmentedControls.buttons["Рецепты"].tap()
        let source = app.segmentedControls["nutrition.recipe.source"]
        XCTAssertTrue(source.waitForExistence(timeout: 5))
        XCTAssertTrue(source.buttons["Все"].isSelected)
        let first = app.buttons["nutrition.recipe.mine.80000000-0000-4000-8000-000000000001"]
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        capture("recipe-library-all", app: app)
        let search = app.textFields["Рецепт или ингредиент"]
        search.tap()
        search.typeText("QA Рецепт 15\n")
        let last = app.buttons["nutrition.recipe.mine.80000000-0000-4000-8000-000000000015"]
        XCTAssertTrue(last.waitForExistence(timeout: 5))
        source.buttons["Мои"].tap()
        XCTAssertTrue(last.exists)
        capture("recipe-library-mine", app: app)
        source.buttons["Каталог"].tap()
        XCTAssertFalse(last.exists)
        XCTAssertTrue(app.staticTexts["Рецепты не найдены"].waitForExistence(timeout: 5))
        app.buttons["Очистить поиск"].tap()
        let bundled = app.buttons["nutrition.recipe.catalog.banana-oatmeal"]
        XCTAssertTrue(bundled.waitForExistence(timeout: 5))
        XCTAssertFalse(first.exists)
        capture("recipe-library-catalog", app: app)
        source.buttons["Все"].tap()
        search.tap()
        search.typeText("QA Рецепт 15\n")
        last.tap()
        XCTAssertTrue(app.navigationBars["Мой рецепт"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["QA Рецепт 15"].exists)
        XCTAssertTrue(app.staticTexts["Ингредиенты"].exists)
        app.buttons["В избранное"].tap()
        capture("recipe-library-own-details", app: app)
        app.navigationBars["Мой рецепт"].buttons["Готово"].tap()
        app.buttons["Очистить поиск"].tap()
        source.buttons["Мои"].tap()
        app.descendants(matching: .any).matching(identifier: "nutrition.recipe.filters").firstMatch.tap()
        let favorites = app.switches["Только избранное"]
        reveal(favorites, in: app)
        favorites.tap()
        XCTAssertTrue(last.exists)
        XCTAssertFalse(first.exists)
        app.terminate()
        app.launch()
        app.buttons["Питание"].tap()
        app.segmentedControls.buttons["Рецепты"].tap()
        XCTAssertTrue(first.waitForExistence(timeout: 5))
    }

    func testDiaryPortionPersistsAndDeletes() {
        let app = launchDiary()
        defer { app.terminate() }
        capture("ios07-day-and-conflict", app: app)

        let breakfast = app.buttons["Добавить: Завтрак"]
        reveal(breakfast, in: app)
        breakfast.tap()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("банан")
        let banana = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Банан,")).firstMatch
        XCTAssertTrue(banana.waitForExistence(timeout: 5))
        banana.tap()
        let mass = app.textFields.firstMatch
        XCTAssertTrue(mass.waitForExistence(timeout: 5))
        mass.tap()
        mass.typeText("125,5")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "121,7 ккал")).firstMatch.exists)
        capture("ios07-portion-keyboard", app: app)
        app.buttons["Сохранить"].tap()
        XCTAssertTrue(app.staticTexts["Дневник питания"].waitForExistence(timeout: 5))
        let saved = app.buttons.matching(NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", "Банан", "125,5")).firstMatch
        reveal(saved, in: app)
        XCTAssertTrue(saved.exists)
        capture("ios07-day-saved", app: app)
        let remove = app.buttons["Удалить Банан"]
        XCTAssertTrue(remove.exists)
        remove.tap()
        app.buttons["Удалить запись"].tap()
        XCTAssertFalse(saved.exists)
    }

    func testManualGoal() {
        let app = launchDiary()
        defer { app.terminate() }
        openMenu(app)
        app.buttons["Цели питания"].tap()
        app.buttons["Добавить цель"].tap()
        fill(app.textFields.element(boundBy: 0), with: "2000", in: app)
        fill(app.textFields.element(boundBy: 1), with: "100", in: app)
        fill(app.textFields.element(boundBy: 2), with: "80", in: app)
        fill(app.textFields.element(boundBy: 3), with: "220", in: app)
        app.buttons["Сохранить"].tap()
        XCTAssertTrue(app.navigationBars["Цели питания"].waitForExistence(timeout: 5))
        let goalEnergy = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@ AND label CONTAINS %@", "Энергия,", "000")).firstMatch
        XCTAssertTrue(goalEnergy.waitForExistence(timeout: 5))
        XCTAssertEqual(goalEnergy.label.filter { !$0.isWhitespace }, "Энергия,2000ккал")
        capture("ios07-goals", app: app)
        app.buttons["Готово"].firstMatch.tap()
    }

    func testCreateOwnRecipeWithIngredient() {
        let app = launchDiary()
        defer { app.terminate() }
        openMenu(app)
        app.buttons["Мои рецепты"].tap()
        app.buttons["Создать рецепт"].tap()
        fill(app.textFields["Название"], with: "QA Вода", in: app)
        app.buttons["Готово"].firstMatch.tap()
        fill(app.textFields["Время, мин"], with: "1", in: app)
        app.buttons["Готово"].firstMatch.tap()
        fill(app.textFields["Количество порций"], with: "1", in: app)
        app.buttons["Готово"].firstMatch.tap()
        fill(app.textFields["Готовая масса, г"], with: "100", in: app)
        app.buttons["Готово"].firstMatch.tap()
        app.buttons["Добавить ингредиент"].tap()
        let ingredientSearch = app.searchFields.firstMatch
        XCTAssertTrue(ingredientSearch.waitForExistence(timeout: 5))
        ingredientSearch.tap()
        ingredientSearch.typeText("вода")
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Питьевая бутилированная вода,")).firstMatch.tap()
        capture("ios07-ingredient-form", app: app)
        XCTAssertTrue(app.navigationBars["Масса ингредиента"].waitForExistence(timeout: 5))
        fill(app.textFields["nutrition.ingredient.grams"], with: "100", in: app)
        app.buttons["Добавить"].tap()
        let steps = app.textViews.firstMatch
        reveal(steps, in: app)
        fill(steps, with: "Налить воду.", in: app)
        app.buttons["Готово"].firstMatch.tap()
        let confirmed = app.switches["Масса соответствует этим ингредиентам"]
        reveal(confirmed, in: app)
        confirmed.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertEqual(confirmed.value as? String, "1")
        capture("ios07-own-recipe", app: app)
        app.buttons["Сохранить"].tap()
        XCTAssertTrue(app.buttons["QA Вода"].waitForExistence(timeout: 5))
        app.buttons["Готово"].firstMatch.tap()
    }

    func testExport() {
        let app = launchDiary()
        defer { app.terminate() }
        openMenu(app)
        app.buttons["Экспорт дневника"].tap()
        XCTAssertTrue(app.buttons["Сохранить JSON"].waitForExistence(timeout: 5))
        capture("ios07-export", app: app)
        app.buttons["Закрыть"].tap()
    }

    private func launchDiary() -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(ru)", "-AppleLocale", "ru_RU"]
        app.launch()
        app.buttons["Питание"].tap()
        XCTAssertTrue(app.staticTexts["Дневник питания"].waitForExistence(timeout: 10))
        return app
    }

    private func openMenu(_ app: XCUIApplication) {
        let menu = app.buttons["Настройки питания"]
        for _ in 0..<5 where !menu.isHittable { app.swipeDown() }
        XCTAssertTrue(menu.isHittable)
        menu.tap()
    }

    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<6 where !element.isHittable {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45)).press(forDuration: 0.1,
                thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)))
        }
        XCTAssertTrue(element.isHittable)
    }

    private func fill(_ element: XCUIElement, with value: String, in app: XCUIApplication) {
        reveal(element, in: app)
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        element.typeText(value)
    }

    private func capture(_ name: String, app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
