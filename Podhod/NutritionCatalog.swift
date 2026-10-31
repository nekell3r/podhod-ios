import Foundation

struct NutritionCatalog: Decodable, Equatable {
    struct RecipeAttribution: Decodable, Equatable {
        let author: String
        let origin: String
    }
    let formatVersion: Int
    let version: String
    let foods: [NutritionFood]
    let recipes: [NutritionRecipe]
    let recipeAttribution: RecipeAttribution

    static let bundled: NutritionCatalog? = {
        #if SWIFT_PACKAGE
        let bundle = Bundle.module
        #else
        let bundle = Bundle.main
        #endif
        guard let url = bundle.url(forResource: "nutrition-catalog", withExtension: "json") else { return nil }
        return try? NutritionCatalog(data: Data(contentsOf: url))
    }()

    init(data: Data) throws {
        self = try JSONDecoder().decode(Self.self, from: data)
        guard formatVersion == 1, !version.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !foods.isEmpty, !recipes.isEmpty,
              Set(foods.map(\.id)).count == foods.count, Set(recipes.map(\.id)).count == recipes.count,
              recipeAttribution.author == "Подход", recipeAttribution.origin == "original" else { throw NutritionError.invalidCatalog }
        for food in foods {
            let source = food.source
            guard food.id == "usda-\(source.fdcID)", source.fdcID > 0, food.per100Grams.isValidPer100Grams,
                  !food.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !food.preparation.isEmpty,
                  source.publisher == "USDA FoodData Central", source.license == "CC0-1.0",
                  source.archiveSHA256.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
                  URL(string: source.url)?.scheme == "https", URL(string: source.url)?.host == "fdc.nal.usda.gov",
                  source.nutrientIDs["proteinGrams"] == 1003, source.nutrientIDs["fatGrams"] == 1004,
                  source.nutrientIDs["carbohydrateGrams"] == 1005,
                  let energyID = source.nutrientIDs["energyKcal"], [1008, 2047, 2048].contains(energyID),
                  source.energyValues.contains(where: { $0.nutrientID == energyID && $0.unit == "kcal" && $0.amount == food.per100Grams.energyKcal }),
                  source.energyValues.allSatisfy({ $0.amount.isFinite && $0.amount >= 0 && $0.unit == "kcal" }) else {
                throw NutritionError.invalidCatalog
            }
        }
        for recipe in recipes {
            guard !recipe.id.isEmpty, !recipe.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  (1...1440).contains(recipe.minutes), (1...50).contains(recipe.ingredients.count),
                  (1...30).contains(recipe.steps.count), recipe.steps.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
                  NutritionRecipeCalculation(recipe: recipe, foods: foods) != nil else { throw NutritionError.invalidCatalog }
            if let address = recipe.safetyURL {
                guard let url = URL(string: address), url.scheme == "https", url.host == "www.foodsafety.gov" else { throw NutritionError.invalidCatalog }
            }
        }
    }

    func food(id: String) -> NutritionFood? { foods.first { $0.id == id } }

    func searchRecipes(query: String, category: NutritionRecipeCategory? = nil, quickOnly: Bool = false, proteinOnly: Bool = false) -> [NutritionRecipe] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return recipes.filter { recipe in
            (category == nil || recipe.category == category) && (!quickOnly || recipe.minutes <= 20) &&
                (!proteinOnly || (NutritionRecipeCalculation(recipe: recipe, foods: foods)?.perServing.proteinGrams ?? 0) >= 20) &&
                (query.isEmpty || recipe.name.localizedStandardContains(query) || recipe.ingredients.contains {
                    food(id: $0.foodID)?.matches(query: query) == true
                })
        }
    }
}
