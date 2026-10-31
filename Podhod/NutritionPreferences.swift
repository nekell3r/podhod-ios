import Foundation
import Observation

private struct NutritionPreferencesArchive: Codable {
    var version = 1
    var favoriteRecipeIDs: [String]
    var favoriteFoodIDs: [String]
}

@MainActor @Observable
final class NutritionPreferences {
    private var localRecipeIDs: Set<String> = []
    private var localFoodIDs: Set<String> = []
    var favoriteRecipeIDs: Set<String> { diary.map { Set($0.archive.preferences.document.favoriteRecipeIDs) } ?? localRecipeIDs }
    var favoriteFoodIDs: Set<String> { diary.map { Set($0.archive.preferences.document.favoriteFoodIDs) } ?? localFoodIDs }
    private(set) var loadFailed = false
    var errorMessage: String?
    @ObservationIgnored let fileURL: URL
    @ObservationIgnored var accountStorageError: String?
    private var diary: NutritionDiaryStore?

    init(diary: NutritionDiaryStore) {
        self.diary = diary
        fileURL = diary.fileURL
        loadFailed = diary.loadFailed
        errorMessage = diary.errorMessage
    }

    init(fileURL: URL) {
        self.fileURL = fileURL
        do {
            if FileManager.default.fileExists(atPath: fileURL.path) {
                let archive = try JSONDecoder().decode(NutritionPreferencesArchive.self, from: Data(contentsOf: fileURL))
                guard archive.version == 1 else { throw NutritionError.unsupportedPreferences }
                guard archive.favoriteRecipeIDs.count + archive.favoriteFoodIDs.count <= 500,
                      Set(archive.favoriteRecipeIDs).count == archive.favoriteRecipeIDs.count,
                      Set(archive.favoriteFoodIDs).count == archive.favoriteFoodIDs.count,
                      (archive.favoriteRecipeIDs + archive.favoriteFoodIDs).allSatisfy({ !$0.isEmpty && $0.count <= 200 }) else {
                    throw NutritionError.invalidPreferences
                }
                localRecipeIDs = Set(archive.favoriteRecipeIDs)
                localFoodIDs = Set(archive.favoriteFoodIDs)
            }
        } catch {
            loadFailed = true
            errorMessage = (error as? NutritionError)?.localizedDescription ?? NutritionError.invalidPreferences.localizedDescription
        }
    }

    @discardableResult
    func setFavoriteRecipe(_ id: String, favorite: Bool) -> Bool {
        var recipes = favoriteRecipeIDs
        if favorite { recipes.insert(id) } else { recipes.remove(id) }
        return save(recipes: recipes, foods: favoriteFoodIDs)
    }

    @discardableResult
    func setFavoriteFood(_ id: String, favorite: Bool) -> Bool {
        var foods = favoriteFoodIDs
        if favorite { foods.insert(id) } else { foods.remove(id) }
        return save(recipes: favoriteRecipeIDs, foods: foods)
    }

    private func save(recipes: Set<String>, foods: Set<String>) -> Bool {
        guard !loadFailed, accountStorageError == nil, recipes.count + foods.count <= 500,
              (recipes.union(foods)).allSatisfy({ !$0.isEmpty && $0.count <= 200 }) else {
            errorMessage = NutritionError.invalidPreferences.localizedDescription
            return false
        }
        do {
            if let diary {
                let saved = diary.savePreferences(NutritionPreferencesDocument(favoriteRecipeIDs: recipes.sorted(), favoriteFoodIDs: foods.sorted()))
                errorMessage = diary.errorMessage
                return saved
            }
            let data = try JSONEncoder().encode(NutritionPreferencesArchive(favoriteRecipeIDs: recipes.sorted(), favoriteFoodIDs: foods.sorted()))
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: fileURL, options: .atomic)
            localRecipeIDs = recipes
            localFoodIDs = foods
            errorMessage = nil
            return true
        } catch {
            errorMessage = NutritionError.saveFailed.localizedDescription
            return false
        }
    }
}
