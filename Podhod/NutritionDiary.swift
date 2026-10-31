import Foundation

enum NutritionMeal: String, Codable, CaseIterable, Identifiable {
    case breakfast, lunch, dinner, snack
    var id: Self { self }
    var title: String {
        switch self {
        case .breakfast: "Завтрак"
        case .lunch: "Обед"
        case .dinner: "Ужин"
        case .snack: "Перекус"
        }
    }
}

struct NutritionOrigin: Codable, Equatable {
    enum Kind: String, Codable { case manual, catalogFood, catalogRecipe, ownRecipe }
    var kind: Kind
    var id: String
    var catalogVersion: String

    static let manual = NutritionOrigin(kind: .manual, id: "", catalogVersion: "")

    var isValid: Bool {
        switch kind {
        case .manual: id.isEmpty && catalogVersion.isEmpty
        case .ownRecipe: UUID(uuidString: id) != nil && catalogVersion.isEmpty
        case .catalogRecipe: !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && id.unicodeScalars.count <= 200 && validCatalogVersion
        case .catalogFood:
            if id.hasPrefix("usda-"), let number = Int(id.dropFirst(5)), number > 0 {
                id == "usda-\(number)" && validCatalogVersion
            } else { false }
        }
    }

    private var validCatalogVersion: Bool {
        !catalogVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && catalogVersion.unicodeScalars.count <= 100
    }
}

struct NutritionFoodSnapshot: Codable, Equatable {
    var name: String
    var per100Grams: NutritionFacts
    var origin: NutritionOrigin

    init(name: String, per100Grams: NutritionFacts, origin: NutritionOrigin = .manual) {
        self.name = name
        self.per100Grams = per100Grams
        self.origin = origin
    }

    init(food: NutritionFood, catalogVersion: String) {
        name = food.name
        per100Grams = food.per100Grams
        origin = NutritionOrigin(kind: .catalogFood, id: food.id, catalogVersion: catalogVersion)
    }

    var isValid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && name.unicodeScalars.count <= 200 &&
            per100Grams.isValidPer100Grams && origin.isValid
    }
}

struct NutritionDiaryEntry: Codable, Equatable, Identifiable {
    var id = UUID()
    var meal: NutritionMeal
    var grams: Double
    var food: NutritionFoodSnapshot

    var amount: NutritionFacts? { food.isValid ? food.per100Grams.amount(forGrams: grams) : nil }
    var isValid: Bool { amount != nil }
}

struct NutritionGoal: Codable, Equatable, Identifiable {
    var id = UUID()
    var effectiveFrom: String
    var timezone: String
    var target: NutritionFacts

    var isValid: Bool {
        timezone != "Local" && TimeZone(identifier: timezone) != nil &&
            TrainingCalendar(timezone: timezone).date(from: effectiveFrom) != nil &&
            target.isValid && target.energyKcal > 0 && target.energyKcal <= 20_000 &&
            target.proteinGrams <= 3000 && target.fatGrams <= 3000 && target.carbohydrateGrams <= 3000
    }
}

struct NutritionDayDocument: Codable, Equatable, Identifiable {
    var version = 1
    var date: String
    var timezone: String
    var entries: [NutritionDiaryEntry] = []
    var goal: NutritionGoal?
    var id: String { date }

    var isValid: Bool {
        version == 1 && timezone != "Local" && TimeZone(identifier: timezone) != nil &&
            TrainingCalendar(timezone: timezone).date(from: date) != nil && entries.count <= 100 &&
            Set(entries.map(\.id)).count == entries.count && entries.allSatisfy(\.isValid) &&
            (goal.map { $0.isValid && $0.effectiveFrom <= date } ?? true) && totals != nil
    }

    var totals: NutritionFacts? {
        var total = NutritionFacts.zero
        for entry in entries {
            guard let amount = entry.amount, let sum = total.adding(amount) else { return nil }
            total = sum
        }
        return total
    }

    func totals(for meal: NutritionMeal) -> NutritionFacts? {
        var selection = self
        selection.entries = entries.filter { $0.meal == meal }
        return selection.totals
    }

    func preservesSnapshot(of other: NutritionDayDocument) -> Bool {
        date == other.date && timezone == other.timezone && goal == other.goal
    }
}

struct NutritionGoalsDocument: Codable, Equatable {
    var version = 1
    var goals: [NutritionGoal] = []
    var isValid: Bool {
        version == 1 && goals.count <= 100 && Set(goals.map(\.id)).count == goals.count &&
            Set(goals.map(\.effectiveFrom)).count == goals.count && goals.allSatisfy(\.isValid)
    }

    func goal(on date: String) -> NutritionGoal? {
        goals.filter { $0.effectiveFrom <= date }.max { $0.effectiveFrom < $1.effectiveFrom }
    }
}

struct NutritionRecipeIngredient: Codable, Equatable, Identifiable {
    var id = UUID()
    var grams: Double
    var food: NutritionFoodSnapshot
    var isValid: Bool { food.isValid && food.per100Grams.amount(forGrams: grams) != nil }
}

struct NutritionOwnRecipe: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    var category: NutritionRecipeCategory
    var minutes: Int
    var servings: Double
    var preparedWeightGrams: Double
    var ingredients: [NutritionRecipeIngredient]
    var steps: [String]

    var isValid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && name.unicodeScalars.count <= 200 &&
            (1...1440).contains(minutes) && servings.isFinite && servings > 0 && servings <= 1000 &&
            preparedWeightGrams.isFinite && preparedWeightGrams > 0 && preparedWeightGrams <= 100_000 &&
            (1...50).contains(ingredients.count) && Set(ingredients.map(\.id)).count == ingredients.count &&
            ingredients.allSatisfy(\.isValid) && (1...30).contains(steps.count) &&
            steps.allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.unicodeScalars.count <= 2000 } &&
            per100Grams?.isValidPer100Grams == true
    }

    var total: NutritionFacts? {
        var total = NutritionFacts.zero
        for ingredient in ingredients {
            guard ingredient.isValid, let amount = ingredient.food.per100Grams.amount(forGrams: ingredient.grams),
                  let sum = total.adding(amount) else { return nil }
            total = sum
        }
        return total
    }

    var per100Grams: NutritionFacts? {
        guard preparedWeightGrams.isFinite, preparedWeightGrams > 0 else { return nil }
        return total?.scaled(by: 100 / preparedWeightGrams)
    }

    var perServing: NutritionFacts? {
        guard servings.isFinite, servings > 0 else { return nil }
        return total?.scaled(by: 1 / servings)
    }

    var snapshot: NutritionFoodSnapshot? {
        guard isValid, let per100Grams else { return nil }
        return NutritionFoodSnapshot(name: name, per100Grams: per100Grams,
            origin: NutritionOrigin(kind: .ownRecipe, id: id.uuidString, catalogVersion: ""))
    }
}

struct NutritionRecipesDocument: Codable, Equatable {
    var version = 1
    var recipes: [NutritionOwnRecipe] = []
    var isValid: Bool {
        version == 1 && recipes.count <= 100 && Set(recipes.map(\.id)).count == recipes.count && recipes.allSatisfy(\.isValid)
    }
}

struct NutritionPreferencesDocument: Codable, Equatable {
    var version = 1
    var favoriteRecipeIDs: [String] = []
    var favoriteFoodIDs: [String] = []
    var isValid: Bool {
        version == 1 && favoriteRecipeIDs.count + favoriteFoodIDs.count <= 500 &&
            Set(favoriteRecipeIDs).count == favoriteRecipeIDs.count && Set(favoriteFoodIDs).count == favoriteFoodIDs.count &&
            (favoriteRecipeIDs + favoriteFoodIDs).allSatisfy {
                !$0.isEmpty && $0.unicodeScalars.count <= 200 && $0 == $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }
    }
}

struct NutritionExportRange {
    let dayKeys: [String]
    let timezone: String

    init(from start: String, through end: String, timezone: String) throws {
        guard timezone != "Local", TimeZone(identifier: timezone) != nil else { throw NutritionDiaryError.exportRange }
        let calendar = TrainingCalendar(timezone: timezone)
        guard let first = calendar.date(from: start), let last = calendar.date(from: end), first <= last else {
            throw NutritionDiaryError.exportRange
        }
        var days: [String] = []
        var date = first
        while date <= last {
            guard days.count < 366 else { throw NutritionDiaryError.exportRange }
            days.append(calendar.dayKey(for: date))
            if date == last { break }
            guard let next = calendar.calendar.date(byAdding: .day, value: 1, to: date), next > date else {
                throw NutritionDiaryError.exportRange
            }
            date = next
        }
        dayKeys = days
        self.timezone = timezone
    }
}

struct NutritionDiaryExport: Encodable {
    let version = 1
    var source: String
    var days: [NutritionDocumentRecord<NutritionDayDocument>]
}
