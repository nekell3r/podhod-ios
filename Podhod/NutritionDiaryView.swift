import SwiftUI

struct NutritionHomeView: View {
    var preferences: NutritionPreferences
    var diary: NutritionDiaryStore
    var sync: NutritionSynchronization
    @State private var section = 0

    var body: some View {
        VStack(spacing: 0) {
            Picker("Раздел питания", selection: $section) {
                Text("Дневник").tag(0)
                Text("Рецепты").tag(1)
            }.pickerStyle(.segmented).padding(.horizontal, 22).padding(.top, 16)
            if section == 0 { NutritionDiaryView(store: diary, sync: sync) }
            else { NutritionView(preferences: preferences, diary: diary, sync: sync) }
        }
    }
}

struct NutritionDiaryView: View {
    @Bindable var store: NutritionDiaryStore
    var sync: NutritionSynchronization
    @State private var selectedDate = Date()
    @State private var addingMeal: NutritionMeal?
    @State private var editingEntry: NutritionDiaryEntry?
    @State private var deletingEntry: NutritionDiaryEntry?
    @State private var showGoals = false
    @State private var showOwnRecipes = false
    @State private var showExport = false
    private var timezone: String { TimeZone.autoupdatingCurrent.identifier }
    private var key: String { TrainingCalendar(timezone: timezone).dayKey(for: selectedDate) }
    private var day: NutritionDayDocument { store.day(key, timezone: timezone) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Дневник питания").font(.system(.title, design: .rounded).bold())
                    Spacer(minLength: 8)
                    Menu {
                        Button("Цели питания", systemImage: "target") { showGoals = true }
                        Button("Мои рецепты", systemImage: "book") { showOwnRecipes = true }
                        Button("Экспорт дневника", systemImage: "square.and.arrow.up") { showExport = true }
                    } label: { Image(systemName: "ellipsis.circle").font(.title2).frame(minWidth: 44, minHeight: 44) }
                        .accessibilityLabel("Настройки питания")
                }
                DatePicker("День", selection: $selectedDate, displayedComponents: .date)
                    .datePickerStyle(.compact)
                VStack(alignment: .leading, spacing: 14) {
                    Text("За день").font(.headline)
                    if let totals = day.totals {
                        NutritionValuesView(facts: totals)
                    }
                    if let goal = day.goal {
                        Divider()
                        Text("Цель дня: \(goal.target.energyKcal.formatted(.number.precision(.fractionLength(0)))) ккал")
                            .font(.subheadline.weight(.semibold))
                        Text("Б \(weightText(goal.target.proteinGrams)) · Ж \(weightText(goal.target.fatGrams)) · У \(weightText(goal.target.carbohydrateGrams)) г")
                            .font(.caption).foregroundStyle(Color.gymMuted)
                    } else {
                        Button("Задать цель для новых дней") { showGoals = true }.font(.subheadline)
                        Text("Уже записанные дни сохраняют свою цель, включая её отсутствие.").font(.caption).foregroundStyle(Color.gymMuted)
                    }
                    Text("Часовой пояс: \(day.timezone)").font(.caption2).foregroundStyle(Color.gymMuted)
                }.modifier(GymCard())
                VStack(alignment: .leading, spacing: 12) {
                    Text(sync.status).font(.caption).foregroundStyle(Color.gymMuted)
                    ForEach(sync.conflicts) { conflict in
                        VStack(alignment: .leading, spacing: 10) {
                            Label(conflict.title, systemImage: "exclamationmark.icloud").font(.subheadline.bold())
                            Text("На iPhone и сервере разные записи. Выбор сохранит резервную копию обеих версий.").font(.caption)
                            if !sync.canResolve { Text("Для выбора версии нужен вход в аккаунт и доступный сервер.").font(.caption) }
                            if !sync.canKeepLocal(conflict) {
                                Text("На сервере у этого дня другой снимок цели или часовой пояс. Свою версию нельзя записать поверх него; локальная копия сохранится.").font(.caption)
                            }
                            HStack {
                                Button("Оставить iPhone") { Task { await sync.resolve(conflict, usingServer: false) } }
                                    .disabled(!sync.canKeepLocal(conflict) || !sync.canResolve)
                                Spacer()
                                Button("Взять сервер") { Task { await sync.resolve(conflict, usingServer: true) } }.disabled(!sync.canResolve)
                            }.font(.subheadline)
                        }.padding(16).background(Color.gymCard, in: RoundedRectangle(cornerRadius: 14))
                    }
                    if let error = sync.resolutionError { Text(error).font(.caption).foregroundStyle(Color.orange) }
                }
                ForEach(NutritionMeal.allCases) { meal in
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text(meal.title).font(.system(.title3, design: .rounded).bold())
                            Spacer()
                            Button { addingMeal = meal } label: { Image(systemName: "plus.circle.fill").font(.title2).frame(width: 44, height: 44) }
                                .accessibilityLabel("Добавить: \(meal.title)").disabled(store.loadFailed)
                        }
                        let entries = day.entries.filter { $0.meal == meal }
                        if entries.isEmpty {
                            Button { addingMeal = meal } label: {
                                Text("Добавить еду").font(.subheadline).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 12)
                            }.disabled(store.loadFailed)
                        }
                        ForEach(entries) { entry in
                            HStack(alignment: .top, spacing: 12) {
                                Button { editingEntry = entry } label: {
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text(entry.food.name).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                                        Text("\(weightText(entry.grams)) г · \(weightText(entry.amount?.energyKcal ?? 0)) ккал")
                                            .font(.caption).foregroundStyle(Color.gymMuted)
                                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8)
                                }.buttonStyle(.plain)
                                Button(role: .destructive) { deletingEntry = entry } label: {
                                    Image(systemName: "trash").frame(width: 44, height: 44)
                                }.accessibilityLabel("Удалить \(entry.food.name)")
                            }
                            Divider()
                        }
                    }
                }
                Text("Отметки протеина остаются отдельными: они не добавляют еду и калории автоматически.")
                    .font(.caption).foregroundStyle(Color.gymMuted)
            }.padding(.horizontal, 22).padding(.top, 24).padding(.bottom, 24)
        }
        .task(id: key) { sync.focusedDay = key; await sync.synchronize() }
        .sheet(item: $addingMeal) { meal in
            NavigationStack {
                NutritionFoodSelection(store: store) { choice in
                    NutritionEntryEditor(store: store, key: key, timezone: timezone, meal: meal, food: choice.food,
                        gramsPerServing: choice.gramsPerServing) { addingMeal = nil }
                }
            }.tint(.gymLime).preferredColorScheme(.dark)
        }
        .sheet(item: $editingEntry) { entry in
            NavigationStack { NutritionEntryEditor(store: store, key: key, timezone: day.timezone, meal: entry.meal, food: entry.food, existing: entry) { editingEntry = nil } }
                .tint(.gymLime).preferredColorScheme(.dark)
        }
        .sheet(isPresented: $showGoals) { NavigationStack { NutritionGoalsView(store: store) }.tint(.gymLime).preferredColorScheme(.dark) }
        .sheet(isPresented: $showOwnRecipes) { NavigationStack { NutritionOwnRecipesView(store: store) }.tint(.gymLime).preferredColorScheme(.dark) }
        .sheet(isPresented: $showExport) { NavigationStack { NutritionExportView(sync: sync) }.tint(.gymLime).preferredColorScheme(.dark) }
        .confirmationDialog("Удалить запись о еде?", isPresented: Binding(get: { deletingEntry != nil }, set: { if !$0 { deletingEntry = nil } }), titleVisibility: .visible) {
            Button("Удалить запись", role: .destructive) {
                if let entry = deletingEntry { store.removeEntry(entry.id, on: key, expected: entry) }
                deletingEntry = nil
            }
        }
        .alert("Питание", isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) {
            Button("Понятно") { store.errorMessage = nil }
        } message: { Text(store.errorMessage ?? "") }
    }
}

struct NutritionFoodChoice {
    var food: NutritionFoodSnapshot
    var gramsPerServing: Double?
}

struct NutritionFoodSelection<Destination: View>: View {
    var store: NutritionDiaryStore
    @ViewBuilder var destination: (NutritionFoodChoice) -> Destination
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    private let catalog = NutritionCatalog.bundled

    var body: some View {
        List {
            Section {
                NavigationLink("Ввести продукт вручную") { NutritionManualFoodEditor(destination: destination) }
            }
            if let catalog {
                Section("Продукты") {
                    ForEach(catalog.foods.filter { $0.matches(query: query) }) { food in
                        NavigationLink {
                            destination(NutritionFoodChoice(food: NutritionFoodSnapshot(food: food, catalogVersion: catalog.version)))
                        } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(food.name)
                                Text(food.preparation).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Section("Рецепты каталога") {
                    ForEach(catalog.searchRecipes(query: query)) { recipe in
                        NavigationLink(recipe.name) {
                            NutritionRecipeSnapshotEditor(recipe: recipe, catalog: catalog, destination: destination)
                        }
                    }
                }
            }
            Section("Мои рецепты") {
                ForEach(store.archive.recipes.document.searchRecipes(query: query)) { recipe in
                    if let snapshot = recipe.snapshot {
                        NavigationLink(recipe.name) {
                            destination(NutritionFoodChoice(food: snapshot, gramsPerServing: recipe.preparedWeightGrams / recipe.servings))
                        }
                    }
                }
                if store.archive.recipes.document.recipes.isEmpty {
                    Text("Добавь рецепт кнопкой «+» во вкладке «Рецепты».").font(.caption).foregroundStyle(.secondary)
                }
            }
        }.searchable(text: $query, prompt: "Продукт или рецепт")
            .navigationTitle("Добавить еду")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Закрыть") { dismiss() } } }
    }
}

struct NutritionEntryEditor: View {
    var store: NutritionDiaryStore
    var key: String
    var timezone: String
    var meal: NutritionMeal
    var food: NutritionFoodSnapshot
    var existing: NutritionDiaryEntry?
    var gramsPerServing: Double?
    var completed: () -> Void
    @State private var draftID = UUID()
    @State private var grams = ""
    @State private var selectedMeal: NutritionMeal = .breakfast
    @State private var useServings = false
    @FocusState private var focused: Bool

    private var mass: Double? {
        guard let value = Double(grams.replacingOccurrences(of: ",", with: ".")) else { return nil }
        if useServings && (!value.isFinite || value <= 0 || value > 1000) { return nil }
        return useServings ? value * (gramsPerServing ?? 0) : value
    }
    private var entry: NutritionDiaryEntry? {
        guard let mass else { return nil }
        let value = NutritionDiaryEntry(id: existing?.id ?? draftID, meal: selectedMeal, grams: mass, food: food)
        return value.isValid ? value : nil
    }

    var body: some View {
        Form {
                Section {
                    Text(food.name).font(.title2.bold())
                    Picker("Приём пищи", selection: $selectedMeal) { ForEach(NutritionMeal.allCases) { Text($0.title).tag($0) } }
                    if gramsPerServing != nil {
                        Picker("Количество", selection: $useServings) {
                            Text("Съедено граммов").tag(false)
                            Text("Количество порций").tag(true)
                        }.onChange(of: useServings) { _, _ in grams = "" }
                    }
                    LabeledContent(useServings ? "Съедено порций" : "Съедено, г") {
                        TextField(useServings ? "Порции" : "Масса", text: $grams).multilineTextAlignment(.trailing).focused($focused)
                            #if os(iOS)
                            .keyboardType(.decimalPad)
                            #endif
                    }
                    if useServings, let gramsPerServing {
                        Text("Одна порция — \(weightText(gramsPerServing)) г готового блюда.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let entry, let amount = entry.amount {
                    Section("Эта запись: \(weightText(entry.grams)) г") { NutritionValuesView(facts: amount) }
                } else { Text("Укажи съедобную массу больше 0 и не больше 100 000 г.").font(.caption).foregroundStyle(.secondary) }
                Section("Сохранённый состав на 100 г") {
                    NutritionValuesView(facts: food.per100Grams)
                    Text(food.origin.kind == .manual ? "Введено вручную" : "Снимок состава: изменения рецепта или каталога не изменят эту запись.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let error = store.errorMessage { Text(error).foregroundStyle(Color.orange).font(.caption) }
        }
        .navigationTitle(existing == nil ? "Порция" : "Изменить запись")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Сохранить") {
                        if let entry, store.saveEntry(entry, on: key, timezone: timezone, expected: existing) { focused = false; completed() }
                    }.disabled(entry == nil || store.loadFailed)
                }
            #if os(iOS)
            ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("Готово") { focused = false } }
            #endif
        }
        .onAppear { grams = existing.map { String($0.grams) } ?? ""; selectedMeal = meal }
    }
}

struct NutritionFactsFields: View {
    @Binding var energy: String
    @Binding var protein: String
    @Binding var fat: String
    @Binding var carbohydrate: String
    var body: some View {
        Group {
            LabeledContent("Энергия, ккал") { TextField("Обязательно", text: $energy).multilineTextAlignment(.trailing) }
            LabeledContent("Белки, г") { TextField("Обязательно", text: $protein).multilineTextAlignment(.trailing) }
            LabeledContent("Жиры, г") { TextField("Обязательно", text: $fat).multilineTextAlignment(.trailing) }
            LabeledContent("Углеводы, г") { TextField("Обязательно", text: $carbohydrate).multilineTextAlignment(.trailing) }
        }
        #if os(iOS)
        .keyboardType(.decimalPad)
        #endif
    }

    static func facts(energy: String, protein: String, fat: String, carbohydrate: String) -> NutritionFacts? {
        let values = [energy, protein, fat, carbohydrate].compactMap { Double($0.replacingOccurrences(of: ",", with: ".")) }
        guard values.count == 4 else { return nil }
        let facts = NutritionFacts(energyKcal: values[0], proteinGrams: values[1], fatGrams: values[2], carbohydrateGrams: values[3])
        return facts.isValid ? facts : nil
    }
}

struct NutritionManualFoodEditor<Destination: View>: View {
    @ViewBuilder var destination: (NutritionFoodChoice) -> Destination
    @State private var name = ""
    @State private var energy = ""
    @State private var protein = ""
    @State private var fat = ""
    @State private var carbohydrate = ""
    private var snapshot: NutritionFoodSnapshot? {
        guard let facts = NutritionFactsFields.facts(energy: energy, protein: protein, fat: fat, carbohydrate: carbohydrate) else { return nil }
        let snapshot = NutritionFoodSnapshot(name: name.trimmingCharacters(in: .whitespacesAndNewlines), per100Grams: facts)
        return snapshot.isValid ? snapshot : nil
    }
    var body: some View {
        Form {
            Section { TextField("Название продукта", text: $name) }
            Section("Все значения на 100 г") {
                NutritionFactsFields(energy: $energy, protein: $protein, fat: $fat, carbohydrate: $carbohydrate)
                Text("Перенеси данные с этикетки. Ноль введи явно; неизвестное значение нельзя пропустить.").font(.caption).foregroundStyle(.secondary)
            }
            if let snapshot { NavigationLink("Далее") { destination(NutritionFoodChoice(food: snapshot)) } }
            else { Text("Нужны название и все четыре допустимых значения на 100 г.").font(.caption).foregroundStyle(.secondary) }
        }.navigationTitle("Свой продукт").scrollDismissesKeyboard(.interactively)
    }
}

struct NutritionRecipeSnapshotEditor<Destination: View>: View {
    var recipe: NutritionRecipe
    var catalog: NutritionCatalog
    @ViewBuilder var destination: (NutritionFoodChoice) -> Destination
    @State private var readyMass = ""
    private var calculation: NutritionRecipeCalculation? {
        guard let mass = Double(readyMass.replacingOccurrences(of: ",", with: ".")) else { return nil }
        return NutritionRecipeCalculation(recipe: recipe, foods: catalog.foods, preparedWeightGrams: mass)
    }
    var body: some View {
        Form {
            Section {
                Text(recipe.name).font(.title2.bold())
                Text("Укажи массу всего готового блюда. Ингредиенты берутся из рецепта без изменения.").font(.subheadline)
                LabeledContent("Готовое блюдо, г") {
                    TextField("Взвешенная масса", text: $readyMass).multilineTextAlignment(.trailing)
                        #if os(iOS)
                        .keyboardType(.decimalPad)
                        #endif
                }
                Text("В рецепте ориентир — \(weightText(recipe.preparedWeightGrams)) г. Фактическая масса может отличаться.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let calculation {
                Section("На 100 г готового блюда") { NutritionValuesView(facts: calculation.per100Grams) }
                NavigationLink("Подтвердить массу и выбрать порцию") {
                    destination(NutritionFoodChoice(food: NutritionFoodSnapshot(name: recipe.name, per100Grams: calculation.per100Grams,
                        origin: NutritionOrigin(kind: .catalogRecipe, id: recipe.id, catalogVersion: catalog.version)),
                        gramsPerServing: calculation.preparedWeightGrams / calculation.servings))
                }
            }
        }.navigationTitle("Готовая масса").scrollDismissesKeyboard(.interactively)
    }
}

struct NutritionGoalsView: View {
    var store: NutritionDiaryStore
    @Environment(\.dismiss) private var dismiss
    @State private var deleting: NutritionGoal?
    var body: some View {
        List {
            Section {
                Text("Цель задаётся вручную и применяется при первой записи нового дня. Созданные дни сохраняют прежнюю цель.").font(.subheadline)
                NavigationLink("Добавить цель") { NutritionGoalEditor(store: store) }
            }
            ForEach(store.archive.goals.document.goals.sorted { $0.effectiveFrom > $1.effectiveFrom }) { goal in
                Section("С \(goal.effectiveFrom)") {
                    NutritionValuesView(facts: goal.target)
                    Button("Удалить цель для новых дней", role: .destructive) { deleting = goal }
                }
            }
        }.navigationTitle("Цели питания")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Готово") { dismiss() } } }
            .confirmationDialog("Удалить цель? Старые дни сохранят её снимок.", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
                Button("Удалить", role: .destructive) { if let deleting { store.removeGoal(deleting.id, expected: deleting) }; deleting = nil }
            }
    }
}

struct NutritionGoalEditor: View {
    var store: NutritionDiaryStore
    @Environment(\.dismiss) private var dismiss
    @State private var date = Date()
    @State private var draftID = UUID()
    @State private var energy = ""
    @State private var protein = ""
    @State private var fat = ""
    @State private var carbohydrate = ""
    private var goal: NutritionGoal? {
        guard let facts = NutritionFactsFields.facts(energy: energy, protein: protein, fat: fat, carbohydrate: carbohydrate) else { return nil }
        let timezone = TimeZone.autoupdatingCurrent.identifier
        let goal = NutritionGoal(id: draftID, effectiveFrom: TrainingCalendar(timezone: timezone).dayKey(for: date), timezone: timezone, target: facts)
        return goal.isValid ? goal : nil
    }
    var body: some View {
        Form {
            DatePicker("Действует с", selection: $date, displayedComponents: .date)
            Section("Моя цель на день") {
                NutritionFactsFields(energy: $energy, protein: $protein, fat: $fat, carbohydrate: $carbohydrate)
                Text("Ручные значения, без автоматического расчёта нормы. У каждой цели должна быть своя дата начала.").font(.caption).foregroundStyle(.secondary)
            }
            if let error = store.errorMessage { Text(error).font(.caption).foregroundStyle(Color.orange) }
        }.navigationTitle("Новая цель").scrollDismissesKeyboard(.interactively)
            .toolbar { ToolbarItem(placement: .confirmationAction) {
                Button("Сохранить") { if let goal, store.saveGoal(goal) { dismiss() } }.disabled(goal == nil)
            } }
    }
}

struct NutritionOwnRecipesView: View {
    var store: NutritionDiaryStore
    @Environment(\.dismiss) private var dismiss
    @State private var deleting: NutritionOwnRecipe?
    var body: some View {
        List {
            NavigationLink("Создать рецепт") { NutritionOwnRecipeEditor(store: store) }
            ForEach(store.archive.recipes.document.recipes) { recipe in
                VStack(alignment: .leading, spacing: 8) {
                    NavigationLink(recipe.name) { NutritionOwnRecipeEditor(store: store, existing: recipe) }
                    Text("\(weightText(recipe.servings)) порц. · готовая масса \(weightText(recipe.preparedWeightGrams)) г").font(.caption).foregroundStyle(.secondary)
                    Button("Удалить рецепт", role: .destructive) { deleting = recipe }.font(.caption)
                }.padding(.vertical, 6)
            }
        }.navigationTitle("Мои рецепты")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Готово") { dismiss() } } }
            .confirmationDialog("Удалить рецепт? Записи дневника сохранят его состав.", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
                Button("Удалить", role: .destructive) { if let deleting { store.removeRecipe(deleting.id, expected: deleting) }; deleting = nil }
            }
    }
}

struct NutritionOwnRecipeEditor: View {
    private enum Field: Hashable { case name, minutes, servings, readyMass, steps }
    var store: NutritionDiaryStore
    var existing: NutritionOwnRecipe?
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var category: NutritionRecipeCategory = .main
    @State private var minutes = ""
    @State private var servings = ""
    @State private var readyMass = ""
    @State private var ingredients: [NutritionRecipeIngredient] = []
    @State private var steps = ""
    @State private var addIngredient = false
    @State private var massConfirmed = false
    @State private var draftID = UUID()
    @FocusState private var focused: Field?

    private var recipe: NutritionOwnRecipe? {
        guard let minutes = Int(minutes), let servings = Double(servings.replacingOccurrences(of: ",", with: ".")),
              let mass = Double(readyMass.replacingOccurrences(of: ",", with: ".")) else { return nil }
        let recipe = NutritionOwnRecipe(id: existing?.id ?? draftID, name: name.trimmingCharacters(in: .whitespacesAndNewlines), category: category,
            minutes: minutes, servings: servings, preparedWeightGrams: mass, ingredients: ingredients,
            steps: steps.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
        return recipe.isValid ? recipe : nil
    }

    var body: some View {
        Form {
            Section("Рецепт") {
                TextField("Название", text: $name).focused($focused, equals: .name)
                Picker("Категория", selection: $category) { ForEach(NutritionRecipeCategory.allCases) { Text($0.title).tag($0) } }
                LabeledContent("Время, мин") { TextField("Минуты", text: $minutes).multilineTextAlignment(.trailing).focused($focused, equals: .minutes) }
                LabeledContent("Количество порций") { TextField("Порции", text: $servings).multilineTextAlignment(.trailing).focused($focused, equals: .servings) }
            }
            Section("Ингредиенты") {
                ForEach(ingredients) { ingredient in
                    HStack {
                        Text(ingredient.food.name)
                        Spacer()
                        Text("\(weightText(ingredient.grams)) г").foregroundStyle(.secondary)
                        Button(role: .destructive) { ingredients.removeAll { $0.id == ingredient.id }; massConfirmed = false } label: { Image(systemName: "minus.circle").frame(minWidth: 44, minHeight: 44) }
                            .accessibilityLabel("Убрать \(ingredient.food.name)")
                    }
                }
                Button("Добавить ингредиент") { addIngredient = true }.disabled(ingredients.count >= 50)
            }
            Section("После приготовления") {
                LabeledContent("Готовая масса, г") { TextField("Взвешенная масса", text: $readyMass).multilineTextAlignment(.trailing).focused($focused, equals: .readyMass) }
                Toggle("Масса соответствует этим ингредиентам", isOn: $massConfirmed)
                Text("Изменение ингредиентов требует нового подтверждения массы. Вода меняет массу, но не добавляет нутриенты.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Шаги: каждый с новой строки") {
                TextEditor(text: $steps).frame(minHeight: 120).focused($focused, equals: .steps).accessibilityLabel("Шаги приготовления")
            }
            if let recipe, massConfirmed, let facts = recipe.per100Grams {
                Section("На 100 г готового блюда") { NutritionValuesView(facts: facts) }
            }
            if let error = store.errorMessage { Text(error).font(.caption).foregroundStyle(Color.orange) }
        }.navigationTitle(existing == nil ? "Новый рецепт" : "Изменить рецепт").scrollDismissesKeyboard(.interactively)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Сохранить") { if let recipe, store.saveRecipe(recipe, expected: existing) { dismiss() } }.disabled(recipe == nil || !massConfirmed)
                }
                #if os(iOS)
                ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("Готово") { focused = nil } }
                #endif
            }
            .sheet(isPresented: $addIngredient) {
                NavigationStack {
                    NutritionFoodSelection(store: store) { choice in
                        NutritionIngredientEditor(food: choice.food) { ingredient in
                            guard !ingredients.contains(where: { $0.id == ingredient.id }) else { return }
                            ingredients.append(ingredient); massConfirmed = false; addIngredient = false
                        }
                    }
                }.tint(.gymLime).preferredColorScheme(.dark)
            }
            .onAppear {
                guard let existing, name.isEmpty else { return }
                name = existing.name; category = existing.category; minutes = String(existing.minutes)
                servings = String(existing.servings); readyMass = String(existing.preparedWeightGrams)
                ingredients = existing.ingredients; steps = existing.steps.joined(separator: "\n"); massConfirmed = true
            }
    }
}

struct NutritionIngredientEditor: View {
    var food: NutritionFoodSnapshot
    var save: (NutritionRecipeIngredient) -> Void
    @State private var grams = ""
    @State private var draftID = UUID()
    private var ingredient: NutritionRecipeIngredient? {
        guard let grams = Double(grams.replacingOccurrences(of: ",", with: ".")) else { return nil }
        let ingredient = NutritionRecipeIngredient(id: draftID, grams: grams, food: food)
        return ingredient.isValid ? ingredient : nil
    }
    var body: some View {
        Form {
            Text(food.name).font(.headline)
            LabeledContent("Ингредиент, г") {
                TextField("Съедобная масса", text: $grams).multilineTextAlignment(.trailing).accessibilityIdentifier("nutrition.ingredient.grams")
                    #if os(iOS)
                    .keyboardType(.decimalPad)
                    #endif
            }
            if let ingredient, let facts = ingredient.food.per100Grams.amount(forGrams: ingredient.grams) {
                NutritionValuesView(facts: facts)
            }
        }.navigationTitle("Масса ингредиента")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Добавить") { if let ingredient { save(ingredient) } }.disabled(ingredient == nil) } }
    }
}
