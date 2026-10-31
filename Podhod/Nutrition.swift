import Foundation

struct NutritionFacts: Codable, Equatable {
    let energyKcal: Double
    let proteinGrams: Double
    let fatGrams: Double
    let carbohydrateGrams: Double

    static let zero = NutritionFacts(energyKcal: 0, proteinGrams: 0, fatGrams: 0, carbohydrateGrams: 0)

    var isValid: Bool {
        [energyKcal, proteinGrams, fatGrams, carbohydrateGrams].allSatisfy { $0.isFinite && $0 >= 0 }
    }
    var isValidPer100Grams: Bool {
        isValid && energyKcal <= 1000 && proteinGrams <= 100 && fatGrams <= 100 && carbohydrateGrams <= 100 &&
            proteinGrams + fatGrams + carbohydrateGrams <= 101
    }

    func scaled(by factor: Double) -> NutritionFacts? {
        guard isValid, factor.isFinite, factor >= 0 else { return nil }
        let result = NutritionFacts(energyKcal: energyKcal * factor, proteinGrams: proteinGrams * factor,
            fatGrams: fatGrams * factor, carbohydrateGrams: carbohydrateGrams * factor)
        return result.isValid ? result : nil
    }

    func adding(_ other: NutritionFacts) -> NutritionFacts? {
        guard isValid, other.isValid else { return nil }
        let result = NutritionFacts(energyKcal: energyKcal + other.energyKcal, proteinGrams: proteinGrams + other.proteinGrams,
            fatGrams: fatGrams + other.fatGrams, carbohydrateGrams: carbohydrateGrams + other.carbohydrateGrams)
        return result.isValid ? result : nil
    }

    func amount(forGrams grams: Double) -> NutritionFacts? {
        guard isValidPer100Grams, grams.isFinite, grams > 0, grams <= 100_000 else { return nil }
        return scaled(by: grams / 100)
    }
}

enum NutritionFoodCategory: String, Codable, CaseIterable, Identifiable {
    case protein, dairy, grains, vegetables, fruit, nuts, pantry
    var id: Self { self }
    var title: String {
        switch self {
        case .protein: "Мясо, рыба и яйца"
        case .dairy: "Молочные продукты"
        case .grains: "Крупы"
        case .vegetables: "Овощи"
        case .fruit: "Фрукты"
        case .nuts: "Орехи и пасты"
        case .pantry: "Масло, вода и соль"
        }
    }
}

struct NutritionFoodSource: Codable, Equatable {
    struct EnergyValue: Codable, Equatable {
        let nutrientID: Int
        let amount: Double
        let unit: String
    }
    let publisher: String
    let license: String
    let licenseURL: String
    let dataset: String
    let release: String
    let archiveSHA256: String
    let url: String
    let fdcID: Int
    let description: String
    let publicationDate: String
    let nutrientIDs: [String: Int]
    let energyValues: [EnergyValue]
}

struct NutritionFood: Codable, Equatable, Identifiable {
    let id: String
    let name: String
    let preparation: String
    let aliases: [String]
    let category: NutritionFoodCategory
    let per100Grams: NutritionFacts
    let source: NutritionFoodSource

    func matches(query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty || ([name, preparation] + aliases).contains { $0.localizedStandardContains(query) }
    }
}

enum NutritionRecipeCategory: String, Codable, CaseIterable, Identifiable {
    case breakfast, main, salad, snack
    var id: Self { self }
    var title: String {
        switch self {
        case .breakfast: "Завтраки"
        case .main: "Основные блюда"
        case .salad: "Салаты"
        case .snack: "Перекусы"
        }
    }
}

struct NutritionIngredient: Codable, Equatable, Identifiable {
    let foodID: String
    let grams: Double
    var id: String { foodID }
}

struct NutritionRecipe: Codable, Equatable, Identifiable {
    let id: String
    let name: String
    let category: NutritionRecipeCategory
    let minutes: Int
    let servings: Double
    let preparedWeightGrams: Double
    let ingredients: [NutritionIngredient]
    let steps: [String]
    let allergens: [String]
    let safetyURL: String?
}

struct NutritionRecipeCalculation: Equatable {
    let total: NutritionFacts
    let perServing: NutritionFacts
    let per100Grams: NutritionFacts
    let preparedWeightGrams: Double
    let servings: Double
    let ingredients: [NutritionIngredient]

    init?(recipe: NutritionRecipe, foods: [NutritionFood], scale: Double = 1, preparedWeightGrams: Double? = nil) {
        guard scale.isFinite, scale > 0, scale <= 1000,
              recipe.servings.isFinite, recipe.servings > 0, recipe.servings * scale <= 1000,
              !recipe.ingredients.isEmpty, Set(recipe.ingredients.map(\.foodID)).count == recipe.ingredients.count else { return nil }
        let weight = preparedWeightGrams ?? recipe.preparedWeightGrams * scale
        guard weight.isFinite, weight > 0, weight <= 100_000 else { return nil }
        var total = NutritionFacts.zero
        var ingredients: [NutritionIngredient] = []
        for ingredient in recipe.ingredients {
            let grams = ingredient.grams * scale
            guard let food = foods.first(where: { $0.id == ingredient.foodID }),
                  let amount = food.per100Grams.amount(forGrams: grams), let sum = total.adding(amount) else { return nil }
            total = sum
            ingredients.append(NutritionIngredient(foodID: ingredient.foodID, grams: grams))
        }
        let servings = recipe.servings * scale
        guard let perServing = total.scaled(by: 1 / servings), let per100Grams = total.scaled(by: 100 / weight),
              per100Grams.isValidPer100Grams else { return nil }
        self.total = total
        self.perServing = perServing
        self.per100Grams = per100Grams
        self.preparedWeightGrams = weight
        self.servings = servings
        self.ingredients = ingredients
    }

    func amount(forServings quantity: Double) -> NutritionFacts? {
        guard quantity.isFinite, quantity > 0, quantity <= 1000 else { return nil }
        return perServing.scaled(by: quantity)
    }
}

enum NutritionError: LocalizedError {
    case invalidCatalog, invalidPreferences, unsupportedPreferences, saveFailed
    var errorDescription: String? {
        switch self {
        case .invalidCatalog: "Не удалось открыть каталог питания. Обнови приложение."
        case .invalidPreferences: "Не удалось прочитать избранное. Исходный файл сохранён без изменений."
        case .unsupportedPreferences: "Избранное создано более новой версией приложения. Обнови приложение."
        case .saveFailed: "Не удалось сохранить избранное. Повтори действие; прежние данные сохранены."
        }
    }
}
