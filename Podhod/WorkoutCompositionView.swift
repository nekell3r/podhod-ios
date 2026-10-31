import SwiftUI

struct WorkoutCompositionView: View {
    var store: WorkoutStore
    let sessionID: UUID
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var showAdd = false
    @State private var replacing: SessionExercise?
    @State private var detail: Exercise?

    var body: some View {
        NavigationStack {
            Group {
                if let session = store.archive.active, session.id == sessionID {
                    List {
                        Section {
                            ForEach(session.exercises) { item in
                                let layout = dynamicTypeSize.isAccessibilitySize
                                    ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12)) : AnyLayout(HStackLayout(spacing: 12))
                                layout {
                                    if !dynamicTypeSize.isAccessibilitySize {
                                        Image(systemName: item.isCompleted ? "checkmark.circle.fill" : item.isSkipped ? "forward.end.circle" : "circle")
                                        .foregroundStyle(item.id == session.exercises[session.currentExercise].id ? Color.gymLime : .secondary)
                                        .accessibilityHidden(true)
                                    }
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(item.exercise.name).font(.headline)
                                            .lineLimit(nil).fixedSize(horizontal: false, vertical: true)
                                        Text("\(item.sets.filter(\.isCompleted).count) из \(item.sets.count) подходов\(item.isSkipped ? " · пропущено" : "")")
                                            .font(.caption).foregroundStyle(.secondary)
                                            .lineLimit(nil).fixedSize(horizontal: false, vertical: true)
                                    }
                                    if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 4) }
                                    Menu {
                                        Button("К подходам", systemImage: "arrow.right") {
                                            guard let current = store.archive.active, current.id == sessionID,
                                                  let index = current.exercises.firstIndex(where: { $0.id == item.id }) else { return }
                                            store.selectExercise(index)
                                            dismiss()
                                        }
                                        Button("Техника и видео", systemImage: "play.rectangle") { detail = item.exercise }
                                        if !item.isCompleted {
                                            Button(item.isSkipped ? "Вернуть упражнение" : "Пропустить упражнение") {
                                                store.setExerciseSkipped(sessionID: sessionID, exerciseID: item.id, isSkipped: !item.isSkipped)
                                            }
                                        }
                                        if !item.isResolved {
                                            Button("Заменить оставшееся", systemImage: "arrow.triangle.2.circlepath") { replacing = item }
                                                .disabled(session.exercises.count >= 50)
                                        }
                                    } label: {
                                        if dynamicTypeSize.isAccessibilitySize {
                                            Label("Действия", systemImage: "ellipsis.circle").frame(minHeight: 44)
                                        } else {
                                            Image(systemName: "ellipsis.circle").frame(width: 44, height: 44)
                                        }
                                    }.accessibilityLabel("Действия: \(item.exercise.name)")
                                }.fixedSize(horizontal: false, vertical: true).padding(.vertical, 4)
                            }
                            .onMove { offsets, destination in
                                let expected = session.exercises.map(\.id)
                                var ordered = expected
                                ordered.move(fromOffsets: offsets, toOffset: destination)
                                store.reorderActiveExercises(sessionID: sessionID, expectedIDs: expected, orderedIDs: ordered)
                            }
                            Button { showAdd = true } label: {
                                Label("Добавить упражнение", systemImage: "plus.circle")
                            }.disabled(session.exercises.count >= 50)
                        } header: { Text("\(session.exercises.count) из 50 упражнений") }
                        footer: {
                            Text("Изменения относятся только к этой тренировке. Шаблон и неделя сохраняются. Перестановка не меняет записанные результаты и измеренное время.")
                                .lineLimit(nil).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                } else {
                    ContentUnavailableView("Тренировка изменилась", systemImage: "dumbbell",
                        description: Text("Закрой этот экран и открой текущую тренировку."))
                }
            }
            .navigationTitle("Состав тренировки")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Готово") { dismiss() } }
                #if os(iOS)
                ToolbarItem(placement: .primaryAction) { EditButton() }
                #endif
            }
            .sheet(isPresented: $showAdd) { WorkoutExercisePicker(store: store, sessionID: sessionID) }
            .sheet(item: $replacing) { original in
                WorkoutExercisePicker(store: store, sessionID: sessionID, replacing: original)
            }
            .sheet(item: $detail) { ExerciseDetailView(exercise: $0) }
            .alert("Не удалось изменить тренировку", isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) {
                Button("Понятно") { store.errorMessage = nil }
            } message: { Text(store.errorMessage ?? "") }
        }.tint(.gymLime).preferredColorScheme(.dark)
        #if os(macOS)
        .frame(minWidth: 430, minHeight: 650)
        #endif
    }
}

struct WorkoutExercisePicker: View {
    var store: WorkoutStore
    let sessionID: UUID
    var replacing: SessionExercise?
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var similarOnly = true
    @State private var equipmentID: String?
    @State private var selected: Exercise?
    @State private var detail: Exercise?
    @State private var setCount = 3
    @State private var targetReps = "8–12"
    @State private var restSeconds = 90
    @State private var restAfterExerciseSeconds = 90
    private let catalog = ExerciseCatalog.bundled

    private var hasMuscleMapping: Bool {
        replacing.map { !(catalog.entry(for: $0.exercise.id)?.primaryMuscles.isEmpty ?? true) } ?? false
    }
    private var matches: [ExerciseCatalogEntry] {
        if let replacing, similarOnly, hasMuscleMapping {
            return catalog.replacements(for: replacing.exercise, query: search, equipmentID: equipmentID)
        }
        let originalID = replacing.map { catalog.entry(for: $0.exercise.id)?.id ?? $0.exercise.id }
        return catalog.search(query: search, equipmentID: equipmentID).filter { $0.id != originalID }
    }
    private var customMatches: [Exercise] {
        guard equipmentID == nil, !(similarOnly && hasMuscleMapping) else { return [] }
        return store.exerciseLibrary.filter {
            catalog.entry(for: $0.id) == nil && $0.id != replacing?.exercise.id &&
                (search.isEmpty || $0.name.localizedStandardContains(search) || $0.muscle.localizedStandardContains(search))
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if let replacing {
                        Text("Вместо: \(replacing.exercise.name)").font(.subheadline.weight(.semibold))
                    }
                    if hasMuscleMapping { Toggle("Те же основные мышцы", isOn: $similarOnly) }
                    Picker("Оборудование", selection: $equipmentID) {
                        Text("Любое").tag(String?.none)
                        ForEach(catalog.equipment) { Text($0.name).tag(Optional($0.id)) }
                    }
                } footer: {
                    Text(hasMuscleMapping && similarOnly
                        ? "Совпадают основные мышцы по каталогу. Выше — больше совпадений мышц и оборудования. Проверь технику перед выбором."
                        : "Выбери упражнение, чтобы проверить технику и параметры перед добавлением.")
                        .lineLimit(nil).fixedSize(horizontal: false, vertical: true)
                }
                if matches.isEmpty && customMatches.isEmpty {
                    ContentUnavailableView.search(text: search)
                    Button("Сбросить поиск и фильтры") { search = ""; similarOnly = false; equipmentID = nil }
                }
                Section("Каталог · \(matches.count)") {
                    ForEach(matches) { entry in
                        Button { selected = entry.exercise } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(entry.exercise.name).font(.headline).foregroundStyle(.primary)
                                    .lineLimit(nil).fixedSize(horizontal: false, vertical: true)
                                Text(entry.exercise.muscle).font(.subheadline).foregroundStyle(.secondary)
                                    .lineLimit(nil).fixedSize(horizontal: false, vertical: true)
                                Text(catalog.equipment.filter { entry.equipment.contains($0.id) }.map(\.name).joined(separator: ", "))
                                    .font(.caption).foregroundStyle(.secondary)
                                    .lineLimit(nil).fixedSize(horizontal: false, vertical: true)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                                .fixedSize(horizontal: false, vertical: true).padding(.vertical, 6)
                        }.buttonStyle(.plain)
                    }
                }
                if !customMatches.isEmpty {
                    Section("Свои и ранее сохранённые") {
                        ForEach(customMatches) { exercise in
                            Button { selected = exercise } label: {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(exercise.name).font(.headline)
                                        .lineLimit(nil).fixedSize(horizontal: false, vertical: true)
                                    Text(exercise.muscle).font(.subheadline).foregroundStyle(.secondary)
                                        .lineLimit(nil).fixedSize(horizontal: false, vertical: true)
                                }.frame(maxWidth: .infinity, alignment: .leading)
                                    .fixedSize(horizontal: false, vertical: true).padding(.vertical, 6)
                            }.buttonStyle(.plain)
                        }
                    }
                }
            }
            .searchable(text: $search, prompt: "Название, мышцы, оборудование")
            .navigationTitle(replacing == nil ? "Добавить упражнение" : "Замена упражнения")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } } }
            .navigationDestination(item: $selected) { exercise in selection(exercise) }
            .sheet(item: $detail) { ExerciseDetailView(exercise: $0) }
            .alert("Не удалось изменить тренировку", isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) {
                Button("Понятно") { store.errorMessage = nil }
            } message: { Text(store.errorMessage ?? "") }
        }.tint(.gymLime).preferredColorScheme(.dark)
        #if os(macOS)
        .frame(minWidth: 430, minHeight: 650)
        #endif
    }

    private func selection(_ exercise: Exercise) -> some View {
        Form {
            Section {
                Text(exercise.name).font(.title2.bold())
                Text(exercise.muscle).foregroundStyle(.secondary)
                Button { detail = exercise } label: { Label("Техника и видео", systemImage: "play.rectangle") }
            }
            if let replacing {
                Section("Оставшаяся часть") {
                    LabeledContent("Новых подходов", value: "\(replacing.sets.filter { !$0.isCompleted }.count)")
                    LabeledContent("Повторы (цель)", value: replacing.targetReps)
                    Text("Исходное упражнение останется со всеми подходами, запасом и заметкой. Невыполненная часть будет пропущена. Новая карточка получит пустые подходы и прежние настройки отдыха.")
                        .font(.subheadline).foregroundStyle(.secondary)
                    Text("Текущий таймер отдыха продолжит идти. К исходному упражнению можно вернуться через состав тренировки.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Section("Параметры") {
                    Stepper("Подходы: \(setCount)", value: $setCount, in: 1...12)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Повторы (цель)").font(.subheadline)
                        TextField("8–12", text: $targetReps).accessibilityLabel("Целевые повторения")
                    }
                    Stepper("Между подходами: \(restSeconds) с", value: $restSeconds, in: 0...600, step: 15)
                    Stepper("После упражнения: \(restAfterExerciseSeconds) с", value: $restAfterExerciseSeconds, in: 0...600, step: 15)
                }
                Text("Добавляется только в текущую тренировку. Шаблон и календарная неделя сохраняются.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Section {
                Button(replacing == nil ? "Добавить в тренировку" : "Сохранить исходное и добавить замену") {
                    let saved: Bool
                    if let replacing {
                        saved = store.replaceActiveExercise(sessionID: sessionID, original: replacing, with: exercise)
                    } else {
                        saved = store.addActiveExercise(sessionID: sessionID, plan: PlannedExercise(exercise: exercise,
                            setCount: setCount, targetReps: targetReps, restSeconds: restSeconds,
                            restAfterExerciseSeconds: restAfterExerciseSeconds))
                    }
                    if saved { dismiss() }
                }.font(.headline).frame(minHeight: 44)
                    .disabled(replacing == nil && targetReps.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.formStyle(.grouped).navigationTitle("Перед добавлением")
    }
}
