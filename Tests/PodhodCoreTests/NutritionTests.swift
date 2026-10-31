import XCTest
@testable import PodhodCore

final class NutritionTests: XCTestCase {
    private func catalog() throws -> NutritionCatalog {
        try XCTUnwrap(NutritionCatalog.bundled)
    }

    func testBundledCatalogKeepsSourcesAndDistinctPreparationStates() throws {
        let catalog = try catalog()
        XCTAssertEqual(catalog.foods.count, 24)
        XCTAssertEqual(catalog.recipes.count, 16)
        let raw = try XCTUnwrap(catalog.food(id: "usda-2646170"))
        let cooked = try XCTUnwrap(catalog.food(id: "usda-331960"))
        XCTAssertEqual(raw.per100Grams.proteinGrams, 22.5)
        XCTAssertEqual(cooked.per100Grams.proteinGrams, 32.1)
        XCTAssertNotEqual(raw.id, cooked.id)
        XCTAssertEqual(raw.source.nutrientIDs["energyKcal"], 2048)
        XCTAssertEqual(raw.source.energyValues.count, 2)
        XCTAssertEqual(raw.source.license, "CC0-1.0")
        XCTAssertTrue(catalog.recipes.allSatisfy { NutritionRecipeCalculation(recipe: $0, foods: catalog.foods) != nil })
    }

    func testGramCalculationPreservesSourceEnergyWithoutEarlyRounding() throws {
        let oil = try XCTUnwrap(try catalog().food(id: "usda-171413"))
        let tenGrams = try XCTUnwrap(oil.per100Grams.amount(forGrams: 10))
        XCTAssertEqual(tenGrams.energyKcal, 88.4, accuracy: 0.000001)
        XCTAssertEqual(tenGrams.fatGrams, 10)
        XCTAssertNotEqual(tenGrams.energyKcal, 10 * 9)
        let tiny = NutritionFacts(energyKcal: 100, proteinGrams: 49, fatGrams: 0, carbohydrateGrams: 0)
        let amount = try XCTUnwrap(tiny.amount(forGrams: 1))
        var sum = NutritionFacts.zero
        for _ in 0..<10 { sum = try XCTUnwrap(sum.adding(amount)) }
        XCTAssertEqual(sum.proteinGrams, 4.9, accuracy: 0.000001)
    }

    func testRecipeUsesReadyWeightForGramsAndDoesNotInventCaloriesFromEvaporation() throws {
        let catalog = try catalog()
        let recipe = try XCTUnwrap(catalog.recipes.first { $0.id == "banana-oatmeal" })
        let normal = try XCTUnwrap(NutritionRecipeCalculation(recipe: recipe, foods: catalog.foods))
        XCTAssertEqual(normal.total.energyKcal, 424.4, accuracy: 0.000001)
        XCTAssertEqual(normal.perServing.energyKcal, 212.2, accuracy: 0.000001)
        let drier = try XCTUnwrap(NutritionRecipeCalculation(recipe: recipe, foods: catalog.foods, preparedWeightGrams: 350))
        XCTAssertEqual(drier.total, normal.total)
        XCTAssertEqual(drier.perServing, normal.perServing)
        XCTAssertEqual(drier.per100Grams.energyKcal, 424.4 / 3.5, accuracy: 0.000001)
        XCTAssertGreaterThan(drier.per100Grams.energyKcal, normal.per100Grams.energyKcal)
        let half = try XCTUnwrap(drier.amount(forServings: 0.5))
        XCTAssertEqual(half.energyKcal, 106.1, accuracy: 0.000001)
        let grams = try XCTUnwrap(drier.per100Grams.amount(forGrams: 175))
        XCTAssertEqual(grams.energyKcal, drier.perServing.energyKcal, accuracy: 0.000001)
    }

    func testBatchScalingChangesIngredientsAndTotalsButNotCompositionOrOneServing() throws {
        let catalog = try catalog()
        let recipe = try XCTUnwrap(catalog.recipes.first)
        let original = try XCTUnwrap(NutritionRecipeCalculation(recipe: recipe, foods: catalog.foods))
        let larger = try XCTUnwrap(NutritionRecipeCalculation(recipe: recipe, foods: catalog.foods, scale: 1.5))
        XCTAssertEqual(larger.servings, 3)
        XCTAssertEqual(larger.preparedWeightGrams, 645)
        XCTAssertEqual(larger.total.energyKcal, original.total.energyKcal * 1.5, accuracy: 0.000001)
        XCTAssertEqual(larger.perServing.energyKcal, original.perServing.energyKcal, accuracy: 0.000001)
        XCTAssertEqual(larger.per100Grams.energyKcal, original.per100Grams.energyKcal, accuracy: 0.000001)
        XCTAssertEqual(larger.ingredients[0].grams, 90)
        XCTAssertEqual(recipe.ingredients[0].grams, 60)
    }

    func testRejectsInvalidMassesScalesAndOverflowWithoutReplacingThemWithZero() throws {
        let catalog = try catalog()
        let recipe = try XCTUnwrap(catalog.recipes.first)
        for value in [0.0, -1, .nan, .infinity, 100_001] {
            XCTAssertNil(NutritionFacts.zero.amount(forGrams: value))
            XCTAssertNil(NutritionRecipeCalculation(recipe: recipe, foods: catalog.foods, preparedWeightGrams: value))
        }
        for value in [0.0, -1, .nan, .infinity, 1001] {
            XCTAssertNil(NutritionRecipeCalculation(recipe: recipe, foods: catalog.foods, scale: value))
        }
        XCTAssertNil(NutritionRecipeCalculation(recipe: recipe, foods: catalog.foods, preparedWeightGrams: 1))
        XCTAssertNil(NutritionRecipeCalculation(recipe: recipe, foods: []))
        let enormous = NutritionFacts(energyKcal: Double.greatestFiniteMagnitude, proteinGrams: 0, fatGrams: 0, carbohydrateGrams: 0)
        XCTAssertNil(enormous.scaled(by: 2))
        XCTAssertNil(enormous.adding(enormous))
        XCTAssertFalse(NutritionFacts(energyKcal: 1, proteinGrams: 90, fatGrams: 20, carbohydrateGrams: 0).isValidPer100Grams)
    }

    func testZeroNutrientWaterIsValidFoodRatherThanMissingData() throws {
        let water = try XCTUnwrap(try catalog().food(id: "usda-174158"))
        XCTAssertEqual(water.per100Grams, .zero)
        XCTAssertEqual(water.per100Grams.amount(forGrams: 300), .zero)
    }

    func testSearchFindsIngredientsAndFiltersActualPerServingProteinAndTime() throws {
        let catalog = try catalog()
        let almonds = catalog.searchRecipes(query: "  миндаль ")
        XCTAssertTrue(almonds.contains { $0.id == "banana-almond-yogurt" })
        XCTAssertFalse(almonds.contains { $0.id == "chicken-rice-broccoli" })
        XCTAssertTrue(catalog.searchRecipes(query: "", category: .salad).allSatisfy { $0.category == .salad })
        XCTAssertTrue(catalog.searchRecipes(query: "", quickOnly: true).allSatisfy { $0.minutes <= 20 })
        let highProtein = catalog.searchRecipes(query: "", proteinOnly: true)
        XCTAssertFalse(highProtein.isEmpty)
        XCTAssertTrue(highProtein.allSatisfy { (NutritionRecipeCalculation(recipe: $0, foods: catalog.foods)?.perServing.proteinGrams ?? 0) >= 20 })
        XCTAssertTrue(catalog.searchRecipes(query: "not a recipe").isEmpty)
    }

    func testReviewedSearchAliasesFindEverydayNamesWithoutCombiningFoodRecords() throws {
        let catalog = try catalog()
        let chicken = catalog.searchRecipes(query: "курица")
        XCTAssertEqual(Set(chicken.map(\.id)), ["chicken-buckwheat", "chicken-rice-broccoli", "chicken-tomato-salad"])
        XCTAssertTrue(catalog.searchRecipes(query: "помидоры").contains { $0.id == "tomato-omelet" })
        let raw = try XCTUnwrap(catalog.food(id: "usda-2646170"))
        let cooked = try XCTUnwrap(catalog.food(id: "usda-331960"))
        XCTAssertTrue(raw.matches(query: " курица "))
        XCTAssertTrue(cooked.matches(query: "КУРИЦА"))
        XCTAssertNotEqual(raw.per100Grams, cooked.per100Grams)
    }

    func testCatalogRejectsFutureVersionMissingMacrosUnknownIngredientsAndUnsafeLinks() throws {
        let catalog = try catalog()
        let encoder = JSONEncoder()
        let foodData = try encoder.encode(catalog.foods)
        let recipeData = try encoder.encode(catalog.recipes)
        let foods = try XCTUnwrap(JSONSerialization.jsonObject(with: foodData) as? [[String: Any]])
        let recipes = try XCTUnwrap(JSONSerialization.jsonObject(with: recipeData) as? [[String: Any]])
        let original: [String: Any] = ["formatVersion": 1, "version": "test", "foods": foods, "recipes": recipes,
            "recipeAttribution": ["author": "Подход", "origin": "original"]]
        var document = original
        document["formatVersion"] = 2
        XCTAssertThrowsError(try NutritionCatalog(data: JSONSerialization.data(withJSONObject: document)))
        document = original
        var incomplete = foods
        incomplete[0]["per100Grams"] = ["energyKcal": 112, "proteinGrams": 22.5, "fatGrams": 1.93]
        document["foods"] = incomplete
        XCTAssertThrowsError(try NutritionCatalog(data: JSONSerialization.data(withJSONObject: document)))
        document = original
        var invalid = recipes
        invalid[0]["ingredients"] = [["foodID": "unknown", "grams": 100]]
        document["recipes"] = invalid
        XCTAssertThrowsError(try NutritionCatalog(data: JSONSerialization.data(withJSONObject: document)))
        document = original
        invalid = recipes
        invalid[0]["safetyURL"] = "javascript:alert(1)"
        document["recipes"] = invalid
        XCTAssertThrowsError(try NutritionCatalog(data: JSONSerialization.data(withJSONObject: document)))
    }
}
