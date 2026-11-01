import SwiftUI

struct NutritionView: View {
    private enum Source: String, CaseIterable, Identifiable {
        case all = "Все", mine = "Мои", catalog = "Каталог"
        var id: Self { self }
    }
    var preferences: NutritionPreferences
    var diary: NutritionDiaryStore
    var sync: NutritionSynchronization
    private let catalog = NutritionCatalog.bundled
    @State private var source = Source.all
    @State private var query = ""
    @State private var category: NutritionRecipeCategory?
    @State private var quickOnly = false
    @State private var proteinOnly = false
    @State private var favoritesOnly = false
    @State private var selectedRecipe: NutritionRecipe?
    @State private var selectedOwnRecipe: NutritionOwnRecipe?
    @State private var showCreate = false
    @State private var showFoods = false
    @FocusState private var searching: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Питание").font(.system(.largeTitle, design: .rounded).bold())
                        Spacer()
                        Button { showCreate = true } label: { Image(systemName: "plus.circle").font(.title2).frame(width: 44, height: 44) }
                            .foregroundStyle(Color.gymLime).accessibilityLabel("Создать рецепт").disabled(diary.loadFailed)
                    }
                    Text("Простые рецепты и понятный расчёт порций.").font(.subheadline).foregroundStyle(Color.gymMuted)
                }.padding(.top, 24)
                Picker("Источник рецептов", selection: $source) {
                    ForEach(Source.allCases) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).accessibilityIdentifier("nutrition.recipe.source")
                HStack {
                    Label {
                        TextField("Рецепт или ингредиент", text: $query).submitLabel(.search)
                            .focused($searching).onSubmit { searching = false }
                    } icon: { Image(systemName: "magnifyingglass") }
                    if !query.isEmpty { Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }.accessibilityLabel("Очистить поиск") }
                }.padding(14).background(Color.gymCard, in: RoundedRectangle(cornerRadius: 14))
                HStack {
                    Picker("Категория", selection: $category) {
                        Text("Все категории").tag(NutritionRecipeCategory?.none)
                        ForEach(NutritionRecipeCategory.allCases) { Text($0.title).tag(Optional($0)) }
                    }.tint(.gymLime)
                    Spacer()
                    Button { showFoods = true } label: { Label("Продукты", systemImage: "carrot").frame(minHeight: 44) }
                        .foregroundStyle(Color.gymLime).disabled(catalog == nil)
                }.font(.subheadline)
                DisclosureGroup("Фильтры") {
                    VStack(spacing: 12) {
                        Toggle("До 20 минут", isOn: $quickOnly)
                        Toggle("От 20 г белка на порцию", isOn: $proteinOnly)
                        Toggle("Только избранное", isOn: $favoritesOnly)
                    }.font(.subheadline).padding(.top, 12)
                }.tint(.gymLime).accessibilityIdentifier("nutrition.recipe.filters")
                if preferences.loadFailed {
                    Text(preferences.errorMessage ?? NutritionError.invalidPreferences.localizedDescription)
                        .font(.subheadline).foregroundStyle(Color.orange)
                }
                Text(sync.status).font(.caption).foregroundStyle(Color.gymMuted)
                if !sync.conflicts.isEmpty {
                    Text("Выбери версию записей во вкладке «Дневник». Обе версии сохранены.").font(.caption).foregroundStyle(Color.orange)
                }
                if catalog == nil && source != .mine {
                    Text("Встроенный каталог недоступен. Мои рецепты показаны отдельно.").font(.caption).foregroundStyle(Color.orange)
                }
                let ownRecipes = (source == .catalog ? [] : diary.archive.recipes.document.searchRecipes(query: query,
                    category: category, quickOnly: quickOnly, proteinOnly: proteinOnly))
                    .filter { !favoritesOnly || preferences.favoriteRecipeIDs.contains($0.id.uuidString) }
                let recipes = (source == .mine ? [] : catalog?.searchRecipes(query: query, category: category, quickOnly: quickOnly, proteinOnly: proteinOnly) ?? [])
                    .filter { !favoritesOnly || preferences.favoriteRecipeIDs.contains($0.id) }
                if recipes.isEmpty && ownRecipes.isEmpty {
                    ContentUnavailableView("Рецепты не найдены", systemImage: "magnifyingglass",
                        description: Text("Измени запрос или фильтры. Избранное добавляется сердечком в карточке рецепта."))
                    Button("Сбросить поиск и фильтры") { query = ""; source = .all; category = nil; quickOnly = false; proteinOnly = false; favoritesOnly = false }
                        .foregroundStyle(Color.gymLime).frame(minHeight: 44)
                }
                LazyVStack(spacing: 14) {
                    ForEach(ownRecipes) { recipe in
                        Button { selectedOwnRecipe = recipe } label: {
                            VStack(alignment: .leading, spacing: 10) {
                                HStack {
                                    Text("Мой рецепт · \(recipe.category.title)").font(.caption).foregroundStyle(Color.gymMuted)
                                    Spacer(minLength: 8)
                                    if preferences.favoriteRecipeIDs.contains(recipe.id.uuidString) {
                                        Image(systemName: "heart.fill").foregroundStyle(Color.gymLime).accessibilityLabel("В избранном")
                                    }
                                }
                                Text(recipe.name).font(.title3.bold()).foregroundStyle(.white).multilineTextAlignment(.leading)
                                if let value = recipe.perServing {
                                    Text("\(recipe.minutes) мин · \(weightText(value.energyKcal)) ккал · Б \(weightText(value.proteinGrams)) г")
                                        .font(.subheadline).foregroundStyle(Color.gymLime)
                                    Text("КБЖУ на одну порцию").font(.caption).foregroundStyle(Color.gymMuted)
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading).modifier(GymCard())
                        }.buttonStyle(.plain).accessibilityIdentifier("nutrition.recipe.mine.\(recipe.id.uuidString)")
                    }
                    ForEach(recipes) { recipe in
                        Button { selectedRecipe = recipe } label: {
                            if let catalog { recipeRow(recipe, catalog: catalog) }
                        }.buttonStyle(.plain).accessibilityIdentifier("nutrition.recipe.catalog.\(recipe.id)")
                    }
                }
                Text("КБЖУ рассчитаны по ингредиентам и готовой массе блюда. Состав конкретной марки может отличаться. Мои рецепты и избранное хранятся вместе с дневником.")
                    .font(.caption).foregroundStyle(Color.gymMuted)
            }.padding(.horizontal, 22).padding(.bottom, 24)
        }.scrollDismissesKeyboard(.interactively)
        .sheet(item: $selectedRecipe) { recipe in
            if let catalog { NutritionRecipeView(recipe: recipe, catalog: catalog, preferences: preferences) }
        }
        .sheet(item: $selectedOwnRecipe) { recipe in
            NutritionOwnRecipeView(recipeID: recipe.id, store: diary, preferences: preferences)
        }
        .sheet(isPresented: $showCreate) {
            NavigationStack { NutritionOwnRecipeEditor(store: diary) }.tint(.gymLime).preferredColorScheme(.dark)
        }
        .sheet(isPresented: $showFoods) {
            if let catalog { NutritionFoodLibrary(catalog: catalog, preferences: preferences) }
        }
        .task { await sync.synchronize() }
        .onChange(of: source) { _, _ in searching = false }
    }

    private func recipeRow(_ recipe: NutritionRecipe, catalog: NutritionCatalog) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            NutritionRecipeImage(recipeID: recipe.id)
            HStack(alignment: .firstTextBaseline) {
                Text(recipe.category.title).font(.caption).foregroundStyle(Color.gymMuted)
                Spacer(minLength: 8)
                if preferences.favoriteRecipeIDs.contains(recipe.id) {
                    Image(systemName: "heart.fill").foregroundStyle(Color.gymLime).accessibilityLabel("В избранном")
                }
            }
            Text(recipe.name).font(.title3.bold()).foregroundStyle(.white).multilineTextAlignment(.leading)
            if let value = NutritionRecipeCalculation(recipe: recipe, foods: catalog.foods)?.perServing {
                Text("\(recipe.minutes) мин · \(weightText(value.energyKcal)) ккал · Б \(weightText(value.proteinGrams)) г")
                    .font(.subheadline).foregroundStyle(Color.gymLime)
                Text("КБЖУ на одну порцию").font(.caption).foregroundStyle(Color.gymMuted)
            }
        }.frame(maxWidth: .infinity, alignment: .leading).modifier(GymCard())
    }
}

private struct NutritionOwnRecipeView: View {
    var recipeID: UUID
    var store: NutritionDiaryStore
    var preferences: NutritionPreferences
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if let recipe = store.archive.recipes.document.recipes.first(where: { $0.id == recipeID }) {
                    Section {
                        Text(recipe.name).font(.title2.bold())
                        Label("\(recipe.minutes) минут · \(recipe.category.title)", systemImage: "clock").font(.subheadline).foregroundStyle(.secondary)
                        Button {
                            preferences.setFavoriteRecipe(recipe.id.uuidString, favorite: !preferences.favoriteRecipeIDs.contains(recipe.id.uuidString))
                        } label: {
                            Label(preferences.favoriteRecipeIDs.contains(recipe.id.uuidString) ? "Убрать из избранного" : "В избранное",
                                systemImage: preferences.favoriteRecipeIDs.contains(recipe.id.uuidString) ? "heart.fill" : "heart")
                        }.disabled(preferences.loadFailed)
                        NavigationLink("Изменить рецепт") { NutritionOwnRecipeEditor(store: store, existing: recipe) }
                        if let error = preferences.errorMessage { Text(error).font(.caption).foregroundStyle(Color.orange) }
                    }
                    Section("Ингредиенты") {
                        ForEach(recipe.ingredients) { ingredient in
                            LabeledContent(ingredient.food.name, value: "\(weightText(ingredient.grams)) г")
                        }
                    }
                    if let facts = recipe.perServing {
                        Section("На 1 порцию · \(weightText(recipe.preparedWeightGrams / recipe.servings)) г") {
                            NutritionValuesView(facts: facts)
                        }
                    }
                    if let facts = recipe.per100Grams {
                        Section("На 100 г готового блюда") { NutritionValuesView(facts: facts) }
                    }
                    Section("Как приготовить") {
                        ForEach(Array(recipe.steps.enumerated()), id: \.offset) { index, step in
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Шаг \(index + 1)").font(.caption.bold()).foregroundStyle(.secondary)
                                Text(step)
                            }.padding(.vertical, 5)
                        }
                    }
                } else {
                    ContentUnavailableView("Рецепт удалён", systemImage: "book.closed",
                        description: Text("Ранее записанные порции остаются в дневнике."))
                }
            }.navigationTitle("Мой рецепт")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Готово") { dismiss() } } }
        }.tint(.gymLime).preferredColorScheme(.dark)
    }
}

struct NutritionValuesView: View {
    var facts: NutritionFacts
    var body: some View {
        VStack(spacing: 10) {
            LabeledContent("Энергия", value: "\(weightText(facts.energyKcal)) ккал")
            LabeledContent("Белки", value: "\(weightText(facts.proteinGrams)) г")
            LabeledContent("Жиры", value: "\(weightText(facts.fatGrams)) г")
            LabeledContent("Углеводы", value: "\(weightText(facts.carbohydrateGrams)) г")
        }.font(.subheadline).monospacedDigit()
    }
}

private struct NutritionRecipeImage: View {
    var recipeID: String
    private var name: String? {
        switch recipeID {
        case "banana-oatmeal": "RecipeBananaOatmeal"
        case "chicken-rice-broccoli": "RecipeChickenRice"
        default: nil
        }
    }
    var body: some View {
        if let name {
            VStack(alignment: .leading, spacing: 5) {
                Image(name).resizable().scaledToFit().clipShape(RoundedRectangle(cornerRadius: 14)).accessibilityHidden(true)
                Text("Иллюстрация блюда · создана с ИИ").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

struct NutritionRecipeView: View {
    private enum Field: Hashable { case readyMass, quantity }
    var recipe: NutritionRecipe
    var catalog: NutritionCatalog
    var preferences: NutritionPreferences
    @Environment(\.dismiss) private var dismiss
    @State private var cookingServings: Double
    @State private var readyMass: String
    @State private var quantityMode = 0
    @State private var quantity = "1"
    @State private var needsMassConfirmation = false
    @FocusState private var focused: Field?

    init(recipe: NutritionRecipe, catalog: NutritionCatalog, preferences: NutritionPreferences) {
        self.recipe = recipe
        self.catalog = catalog
        self.preferences = preferences
        _cookingServings = State(initialValue: recipe.servings)
        _readyMass = State(initialValue: String(recipe.preparedWeightGrams))
    }

    private var calculation: NutritionRecipeCalculation? {
        guard let grams = Double(readyMass.replacingOccurrences(of: ",", with: ".")) else { return nil }
        return NutritionRecipeCalculation(recipe: recipe, foods: catalog.foods, scale: cookingServings / recipe.servings, preparedWeightGrams: grams)
    }
    private var portion: NutritionFacts? {
        guard !needsMassConfirmation, let calculation, let amount = Double(quantity.replacingOccurrences(of: ",", with: ".")) else { return nil }
        return quantityMode == 0 ? calculation.amount(forServings: amount) : calculation.per100Grams.amount(forGrams: amount)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    NutritionRecipeImage(recipeID: recipe.id)
                    Text(recipe.name).font(.title2.bold())
                    Label("\(recipe.minutes) минут · \(recipe.category.title)", systemImage: "clock").font(.subheadline).foregroundStyle(.secondary)
                    Button {
                        preferences.setFavoriteRecipe(recipe.id, favorite: !preferences.favoriteRecipeIDs.contains(recipe.id))
                    } label: {
                        Label(preferences.favoriteRecipeIDs.contains(recipe.id) ? "Убрать из избранного" : "В избранное",
                            systemImage: preferences.favoriteRecipeIDs.contains(recipe.id) ? "heart.fill" : "heart")
                    }.disabled(preferences.loadFailed)
                    if let error = preferences.errorMessage { Text(error).font(.caption).foregroundStyle(Color.orange) }
                }
                Section("Готовлю") {
                    Stepper("Порций: \(weightText(cookingServings))", value: $cookingServings, in: 0.5...24, step: 0.5)
                    LabeledContent("Готовая масса, г") {
                        TextField("Масса без посуды", text: $readyMass).multilineTextAlignment(.trailing)
                            .focused($focused, equals: .readyMass)
                            #if os(iOS)
                            .keyboardType(.decimalPad)
                            #endif
                    }
                    Text("В рецепте указан ориентир массы. Для своего приготовления взвесь готовое блюдо: вода меняет массу и КБЖУ на 100 г, но не добавляет калории.")
                        .font(.caption).foregroundStyle(.secondary)
                    if needsMassConfirmation {
                        Button("Подтвердить готовую массу") { needsMassConfirmation = false }
                            .disabled(calculation == nil)
                        Text("Количество порций изменилось. Проверь массу нового приготовления.").font(.caption).foregroundStyle(Color.orange)
                    }
                }
                Section("Ингредиенты") {
                    ForEach(recipe.ingredients) { item in
                        if let food = catalog.food(id: item.foodID) {
                            VStack(alignment: .leading, spacing: 5) {
                                LabeledContent(food.name, value: "\(weightText(item.grams * cookingServings / recipe.servings)) г")
                                Text(food.preparation).font(.caption).foregroundStyle(.secondary)
                            }.padding(.vertical, 3)
                        }
                    }
                }
                Section("Моя порция") {
                    Picker("Способ расчёта", selection: $quantityMode) {
                        Text("Порции").tag(0)
                        Text("Граммы").tag(1)
                    }.pickerStyle(.segmented)
                    LabeledContent(quantityMode == 0 ? "Количество порций" : "Масса порции, г") {
                        TextField(quantityMode == 0 ? "Например, 1,5" : "Например, 250", text: $quantity)
                            .multilineTextAlignment(.trailing).focused($focused, equals: .quantity)
                            #if os(iOS)
                            .keyboardType(.decimalPad)
                            #endif
                    }
                    if let portion { NutritionValuesView(facts: portion).padding(.vertical, 6) }
                    else { Text("Проверь положительное количество и готовую массу блюда. После изменения числа порций подтверди массу.").font(.subheadline).foregroundStyle(.secondary) }
                }
                if let calculation, !needsMassConfirmation {
                    Section("На 1 порцию · \(weightText(calculation.preparedWeightGrams / calculation.servings)) г") {
                        NutritionValuesView(facts: calculation.perServing).padding(.vertical, 6)
                    }
                    Section("На 100 г готового блюда") { NutritionValuesView(facts: calculation.per100Grams).padding(.vertical, 6) }
                }
                Section("Как приготовить") {
                    ForEach(Array(recipe.steps.enumerated()), id: \.offset) { index, step in
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Шаг \(index + 1)").font(.caption.bold()).foregroundStyle(.secondary)
                            Text(step).font(.body)
                        }.padding(.vertical, 5)
                    }
                }
                if !recipe.allergens.isEmpty {
                    Section("Аллергены ингредиентов") { Text(recipe.allergens.joined(separator: ", ")).font(.subheadline) }
                }
                Section("Источники") {
                    Text("Рецепт: \(catalog.recipeAttribution.author). Собственная разработка; значения рассчитаны по составу ингредиентов.").font(.subheadline)
                    Text("Состав бренда может отличаться от справочника. Расчёт предполагает, что съедается всё указанное масло и жидкость; слив бульона или жира отдельно не моделируется.")
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(recipe.ingredients) { item in
                        if let food = catalog.food(id: item.foodID) {
                            NutritionSourceView(food: food)
                        }
                    }
                    if let address = recipe.safetyURL, let url = URL(string: address) { Link("Температура готовности · FoodSafety.gov", destination: url) }
                }
            }
            .onChange(of: cookingServings) { _, _ in needsMassConfirmation = true }
            .onChange(of: quantityMode) { _, _ in quantity = quantityMode == 0 ? "1" : "100" }
            .navigationTitle("Рецепт")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Готово") { dismiss() } }
                #if os(iOS)
                ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("Готово") { focused = nil } }
                #endif
            }
        }.tint(.gymLime).preferredColorScheme(.dark)
    }
}

struct NutritionSourceView: View {
    var food: NutritionFood
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(food.name).font(.subheadline.weight(.semibold))
            Text("\(food.source.publisher) · FDC \(String(food.source.fdcID)) · \(food.source.dataset), \(food.source.release)")
                .font(.caption).foregroundStyle(.secondary)
            Text(food.source.description).font(.caption).foregroundStyle(.secondary)
            if let url = URL(string: food.source.url) { Link("Выгрузка USDA · \(food.source.license)", destination: url).font(.caption) }
        }.padding(.vertical, 4)
    }
}

struct NutritionFoodLibrary: View {
    var catalog: NutritionCatalog
    var preferences: NutritionPreferences
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var category: NutritionFoodCategory?
    @State private var favoritesOnly = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Категория", selection: $category) {
                        Text("Все продукты").tag(NutritionFoodCategory?.none)
                        ForEach(NutritionFoodCategory.allCases) { Text($0.title).tag(Optional($0)) }
                    }
                    Toggle("Только избранное", isOn: $favoritesOnly)
                    Text("Смотри состояние продукта: 100 г сырого и готового — разные записи.").font(.caption).foregroundStyle(.secondary)
                }
                let foods = catalog.foods.filter {
                    (category == nil || $0.category == category) && (!favoritesOnly || preferences.favoriteFoodIDs.contains($0.id)) &&
                        $0.matches(query: query)
                }
                if foods.isEmpty { ContentUnavailableView.search(text: query) }
                ForEach(foods) { food in
                    NavigationLink {
                        NutritionFoodView(food: food, preferences: preferences)
                    } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(food.name).font(.headline)
                            Text(food.preparation).font(.caption).foregroundStyle(.secondary)
                            Text("\(weightText(food.per100Grams.energyKcal)) ккал на 100 г").font(.subheadline).foregroundStyle(Color.gymLime)
                        }.padding(.vertical, 4)
                    }
                }
            }.searchable(text: $query, prompt: "Продукт или состояние")
                .navigationTitle("Продукты")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Готово") { dismiss() } } }
        }.tint(.gymLime).preferredColorScheme(.dark)
    }
}

struct NutritionFoodView: View {
    var food: NutritionFood
    var preferences: NutritionPreferences
    @State private var grams = "100"
    @FocusState private var focused: Bool
    var body: some View {
        List {
            Section {
                Text(food.name).font(.title2.bold())
                Text(food.preparation).font(.subheadline).foregroundStyle(.secondary)
                Button {
                    preferences.setFavoriteFood(food.id, favorite: !preferences.favoriteFoodIDs.contains(food.id))
                } label: {
                    Label(preferences.favoriteFoodIDs.contains(food.id) ? "Убрать из избранного" : "В избранное",
                        systemImage: preferences.favoriteFoodIDs.contains(food.id) ? "heart.fill" : "heart")
                }.disabled(preferences.loadFailed)
                if let error = preferences.errorMessage { Text(error).font(.caption).foregroundStyle(Color.orange) }
            }
            Section("Моя порция") {
                LabeledContent("Съедобная масса, г") {
                    TextField("Граммы", text: $grams).multilineTextAlignment(.trailing).focused($focused)
                        #if os(iOS)
                        .keyboardType(.decimalPad)
                        #endif
                }
                if let value = Double(grams.replacingOccurrences(of: ",", with: ".")), let facts = food.per100Grams.amount(forGrams: value) {
                    NutritionValuesView(facts: facts).padding(.vertical, 6)
                } else { Text("Укажи массу больше 0 и не больше 100 000 г.").font(.caption).foregroundStyle(.secondary) }
            }
            Section("На 100 г") { NutritionValuesView(facts: food.per100Grams).padding(.vertical, 6) }
            Section("Источник") { NutritionSourceView(food: food) }
        }
        .navigationTitle("Продукт")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("Готово") { focused = false } } }
        #endif
    }
}
