import SwiftUI

struct ProgramView: View {
    var store: WorkoutStore
    var sync: CloudSynchronization
    var start: () -> Void
    @State private var editingDay: TrainingDay?
    @State private var editingDate: Date?
    @State private var selectedWeek = Date()
    @State private var showTemplate = false
    @State private var detailExercise: Exercise?

    private var dates: [Date] { store.trainingCalendar.weekDates(containing: selectedWeek) }
    private var week: TrainingWeek { store.scheduledWeek(containing: selectedWeek) }
    private var days: [TrainingDay] {
        showTemplate ? store.archive.week : dates.map { week.day(on: $0, calendar: store.trainingCalendar) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Твоя неделя").font(.system(size: 36, weight: .bold, design: .rounded))
                    Text(showTemplate ? "Основа для новых недель." : "План на конкретные даты.")
                        .font(.subheadline).foregroundStyle(Color.gymMuted)
                }.padding(.top, 24)
                Picker("Что редактировать", selection: $showTemplate) {
                    Text("По датам").tag(false)
                    Text("Шаблон недели").tag(true)
                }.pickerStyle(.segmented)
                if !showTemplate {
                    HStack(spacing: 10) {
                        Button { shiftWeek(-1) } label: { Image(systemName: "chevron.left").frame(width: 36, height: 44) }
                        Spacer(minLength: 0)
                        VStack(spacing: 5) {
                            if let first = dates.first, let last = dates.last {
                                Text("\(store.trainingCalendar.dayLabel(for: first)) – \(store.trainingCalendar.dayLabel(for: last))")
                                    .font(.headline)
                            }
                            Button("К этой неделе") { selectedWeek = Date() }.font(.caption)
                        }
                        Spacer(minLength: 0)
                        Button { shiftWeek(1) } label: { Image(systemName: "chevron.right").frame(width: 36, height: 44) }
                    }.buttonStyle(.plain).foregroundStyle(Color.gymLime)
                }
                HStack(spacing: 12) {
                    Image(systemName: "calendar.badge.clock").font(.title2).foregroundStyle(Color.gymLime)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Дней с тренировками: \(days.filter { !$0.exercises.isEmpty }.count)").font(.subheadline.weight(.semibold))
                        Text(showTemplate ? "Изменения не затронут уже созданные недели" : "Изменения относятся только к этой неделе")
                            .font(.caption).foregroundStyle(Color.gymMuted)
                    }
                }.modifier(GymCard())
                DisclosureGroup {
                    MuscleVolumeSummary(volume: ExerciseCatalog.bundled.volume(for: days)).padding(.top, 12)
                } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Нагрузка по мышцам").font(.headline)
                        Text(showTemplate ? "За неделю шаблона" : "За выбранную неделю")
                            .font(.caption).foregroundStyle(Color.gymMuted)
                    }
                }.tint(.gymLime).modifier(GymCard())
                ForEach(days) { day in
                    let date = dates[day.weekday - 1]
                    VStack(alignment: .leading, spacing: 16) {
                        Button {
                            editingDate = showTemplate ? nil : date
                            editingDay = day
                        } label: {
                            HStack(alignment: .top) {
                                VStack(alignment: .leading, spacing: 7) {
                                    HStack(spacing: 9) {
                                        Text(day.name).font(.system(.headline, design: .rounded))
                                        if !showTemplate && store.trainingCalendar.dayKey(for: date) == store.trainingCalendar.dayKey(for: Date()) {
                                            Text("СЕГОДНЯ").font(.system(size: 8, weight: .black)).tracking(1)
                                                .foregroundStyle(Color.gymBackground).padding(.horizontal, 7).padding(.vertical, 4)
                                                .background(Color.gymLime, in: Capsule())
                                        }
                                    }
                                    if !showTemplate {
                                        Text(store.trainingCalendar.dayLabel(for: date)).font(.caption).foregroundStyle(Color.gymLime)
                                    }
                                    Text(day.exercises.isEmpty ? "Отдых или новая тренировка" : (day.title.isEmpty ? "Тренировка" : day.title))
                                        .font(.subheadline).foregroundStyle(Color.gymMuted)
                                }
                                Spacer(minLength: 0)
                                Image(systemName: day.exercises.isEmpty ? "plus" : "pencil").foregroundStyle(Color.gymLime)
                            }.contentShape(Rectangle())
                        }.buttonStyle(.plain)
                        if !day.exercises.isEmpty {
                            VStack(spacing: 2) {
                                ForEach(Array(day.exercises.enumerated()), id: \.element.id) { index, plan in
                                    Button { detailExercise = plan.exercise } label: {
                                        ExerciseRow(plan: plan, number: index + 1)
                                    }.buttonStyle(.plain)
                                        .accessibilityHint("Открыть мышцы, технику и видео упражнения")
                                }
                            }
                            HStack {
                                Text("\(day.exercises.count) упр. / \(day.setCount) подх.").font(.caption).foregroundStyle(Color.gymLime)
                                Spacer()
                                if !showTemplate, let workout = week.workouts.first(where: { $0.plannedDate == store.trainingCalendar.dayKey(for: date) }) {
                                    Menu {
                                        ForEach(Array(dates.enumerated()), id: \.offset) { _, target in
                                            Button("\(TrainingDay.names[TrainingDay.weekday(for: target, calendar: store.trainingCalendar.calendar) - 1]), \(store.trainingCalendar.dayLabel(for: target))") {
                                                store.moveScheduledWorkout(id: workout.id, in: week.weekStart, to: target)
                                            }
                                        }
                                    } label: { Image(systemName: "arrow.left.arrow.right").frame(width: 35, height: 35) }
                                    .accessibilityLabel("Перенести тренировку")
                                }
                                Button {
                                    let started = showTemplate ? store.start(day: day) : store.startScheduled(on: date)
                                    if started { start() }
                                } label: { Label(store.archive.active == nil ? "Начать" : "Продолжить", systemImage: "play.fill").font(.caption.bold()) }
                                .buttonStyle(.plain).foregroundStyle(Color.gymLime)
                            }
                        }
                    }.modifier(GymCard())
                }
                Text(showTemplate ? "Шаблон используется при создании новых недель. Уже начатые и завершённые тренировки сохраняют свою программу." : "Перенос меняет только выбранную неделю. Занятая дата защищена от перезаписи.")
                    .font(.caption).foregroundStyle(Color.gymMuted).padding(.bottom, 20)
            }.padding(.horizontal, 22)
        }
        .task(id: store.trainingCalendar.dayKey(for: store.trainingCalendar.weekStart(containing: selectedWeek))) {
            store.ensureWeek(containing: selectedWeek)
            sync.focusedWeekStart = store.trainingCalendar.dayKey(for: store.trainingCalendar.weekStart(containing: selectedWeek))
        }
        .onDisappear { sync.focusedWeekStart = nil }
        .sheet(item: $editingDay) { day in DayEditor(store: store, day: day, scheduledDate: editingDate) }
        .sheet(item: $detailExercise) { exercise in ExerciseDetailView(exercise: exercise) }
    }

    private func shiftWeek(_ direction: Int) {
        if let date = store.trainingCalendar.calendar.date(byAdding: .weekOfYear, value: direction, to: selectedWeek) {
            selectedWeek = date
        }
    }
}

struct DayEditor: View {
    var store: WorkoutStore
    @State var day: TrainingDay
    var scheduledDate: Date?
    @State private var originalDay: TrainingDay

    init(store: WorkoutStore, day: TrainingDay, scheduledDate: Date? = nil) {
        self.store = store
        _day = State(initialValue: day)
        self.scheduledDate = scheduledDate
        _originalDay = State(initialValue: day)
    }

    @Environment(\.dismiss) private var dismiss
    @State private var showLibrary = false
    @State private var saveError: String?
    @State private var detailExercise: Exercise?
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Например, спина и бицепс", text: $day.title)
                } header: { Text("Название тренировки") }
                Section {
                    if day.exercises.isEmpty {
                        Text("Добавь упражнения. Пустой день будет днём отдыха.")
                            .foregroundStyle(.secondary).padding(.vertical, 12)
                    }
                    ForEach($day.exercises) { $plan in
                        DisclosureGroup {
                            Stepper("Подходы: \(plan.setCount)", value: $plan.setCount, in: 1...12)
                            HStack {
                                Text("Повторы (цель)")
                                Spacer()
                                TextField("8–12", text: $plan.targetReps).multilineTextAlignment(.trailing).frame(width: 90)
                            }
                            Stepper("Между подходами: \(plan.restSeconds) с", value: $plan.restSeconds, in: 0...600, step: 15)
                            Stepper("После упражнения: \(plan.restAfterExerciseSeconds) с", value: $plan.restAfterExerciseSeconds, in: 0...600, step: 15)
                            Button {
                                detailExercise = plan.exercise
                            } label: { Label("Мышцы, техника и видео", systemImage: "info.circle") }
                        } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(plan.exercise.name).foregroundStyle(.primary).font(.headline)
                                Text("\(plan.setCount) подх. × \(plan.targetReps) · отдых \(plan.restSeconds) / \(plan.restAfterExerciseSeconds) с")
                                    .font(.caption).foregroundStyle(.secondary)
                            }.padding(.vertical, 6)
                        }
                    }
                    .onDelete { day.exercises.remove(atOffsets: $0) }
                    .onMove { day.exercises.move(fromOffsets: $0, toOffset: $1) }
                    Button { showLibrary = true } label: { Label("Добавить упражнение", systemImage: "plus.circle.fill") }
                } header: { Text("Упражнения по порядку") }
                footer: { Text("Раскрой упражнение, чтобы настроить подходы, повторы и оба вида отдыха. После последнего упражнения отдых не запускается. Порядок меняется кнопкой «Править».") }
                Section("Нагрузка этого дня") {
                    MuscleVolumeSummary(volume: ExerciseCatalog.bundled.volume(for: day))
                        .padding(.vertical, 6)
                }
            }
            .formStyle(.grouped)
            .navigationTitle(day.name)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Сохранить") {
                        day.title = day.title.trimmingCharacters(in: .whitespacesAndNewlines)
                        let saved = scheduledDate.map { store.saveScheduledDay(day, on: $0, expected: originalDay) } ?? store.saveDay(day, expected: originalDay)
                        if saved { dismiss() }
                        else { saveError = store.errorMessage; store.errorMessage = nil }
                    }.bold()
                }
                #if os(iOS)
                ToolbarItem(placement: .bottomBar) { EditButton() }
                #endif
            }
            .sheet(isPresented: $showLibrary) {
                ExerciseLibrary(exercises: store.exerciseLibrary, plannedExercises: day.exercises) { exercise in
                    day.exercises.append(PlannedExercise(exercise: exercise))
                }
            }
            .sheet(item: $detailExercise) { exercise in ExerciseDetailView(exercise: exercise) }
            .alert("Не удалось сохранить", isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })) {
                Button("Понятно") { saveError = nil }
            } message: { Text(saveError ?? "") }
        }
        .tint(.gymLime).preferredColorScheme(.dark)
        #if os(macOS)
        .frame(minWidth: 430, minHeight: 650)
        #endif
    }
}

struct ExerciseLibrary: View {
    var exercises: [Exercise]
    var plannedExercises: [PlannedExercise]
    var add: (Exercise) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var muscleID: String?
    @State private var equipmentID: String?
    @State private var detailExercise: Exercise?
    @State private var showCustom = false
    @State private var addedCount = 0
    private let catalog = ExerciseCatalog.bundled

    private var matchingEntries: [ExerciseCatalogEntry] {
        catalog.search(query: search, muscleID: muscleID, equipmentID: equipmentID)
    }

    private var matchingCustoms: [Exercise] {
        guard muscleID == nil, equipmentID == nil else { return [] }
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return exercises.filter {
            catalog.entry(for: $0.id) == nil && (query.isEmpty || $0.name.localizedStandardContains(query) || $0.muscle.localizedStandardContains(query))
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 12) { muscleFilter; equipmentFilter }
                        VStack(alignment: .leading, spacing: 12) { muscleFilter; equipmentFilter }
                    }
                    if muscleID != nil || equipmentID != nil {
                        Button("Сбросить фильтры") { muscleID = nil; equipmentID = nil }.font(.caption)
                    }
                    Text("Найдено: \(matchingEntries.count + matchingCustoms.count) · В тренировке: \(plannedExercises.count)")
                        .font(.caption).foregroundStyle(.secondary)
                    if addedCount > 0 {
                        Label("Добавлено: \(addedCount). Можно выбрать ещё.", systemImage: "checkmark.circle.fill")
                            .font(.caption).foregroundStyle(Color.gymLime)
                    }
                } footer: {
                    Text("Нажми на название, чтобы посмотреть мышцы и технику. Кнопка «+» добавляет упражнение в текущий черновик.")
                }
                if matchingEntries.isEmpty && matchingCustoms.isEmpty {
                    ContentUnavailableView.search(text: search)
                    Button("Показать все упражнения") { search = ""; muscleID = nil; equipmentID = nil }
                }
                if !matchingEntries.isEmpty {
                    Section("Каталог · \(matchingEntries.count)") {
                        ForEach(matchingEntries) { entry in
                            libraryRow(entry.exercise, equipment: catalog.equipment.filter { entry.equipment.contains($0.id) }.map(\.name).joined(separator: ", "))
                        }
                    }
                }
                if !matchingCustoms.isEmpty {
                    Section("Свои и ранее сохранённые") {
                        ForEach(matchingCustoms) { exercise in libraryRow(exercise, equipment: "") }
                    }
                }
            }
            .searchable(text: $search, prompt: "Название, мышцы, оборудование")
            .navigationTitle("Каталог упражнений")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Готово") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button { showCustom = true } label: { Label("Своё", systemImage: "square.and.pencil") }
                }
            }
            .sheet(item: $detailExercise) { exercise in
                ExerciseDetailView(exercise: exercise) {
                    add(exercise)
                    addedCount += 1
                }
            }
            .sheet(isPresented: $showCustom) {
                CustomExerciseEditor { exercise in
                    add(exercise)
                    addedCount += 1
                }
            }
        }.tint(.gymLime).preferredColorScheme(.dark)
        #if os(macOS)
        .frame(minWidth: 430, minHeight: 650)
        #endif
    }

    private var muscleFilter: some View {
        Menu {
            Picker("Мышцы", selection: $muscleID) {
                Text("Все мышцы").tag(String?.none)
                ForEach(catalog.muscles) { muscle in Text(muscle.name).tag(Optional(muscle.id)) }
            }
        } label: {
            Label(catalog.muscles.first { $0.id == muscleID }?.name ?? "Все мышцы", systemImage: "figure.strengthtraining.traditional")
                .font(.subheadline).padding(.vertical, 6)
        }
    }

    private var equipmentFilter: some View {
        Menu {
            Picker("Оборудование", selection: $equipmentID) {
                Text("Всё оборудование").tag(String?.none)
                ForEach(catalog.equipment) { item in Text(item.name).tag(Optional(item.id)) }
            }
        } label: {
            Label(catalog.equipment.first { $0.id == equipmentID }?.name ?? "Всё оборудование", systemImage: "dumbbell")
                .font(.subheadline).padding(.vertical, 6)
        }
    }

    private func libraryRow(_ exercise: Exercise, equipment: String) -> some View {
        let canonicalID = catalog.entry(for: exercise.id)?.id ?? exercise.id
        let count = plannedExercises.filter {
            (catalog.entry(for: $0.exercise.id)?.id ?? $0.exercise.id) == canonicalID
        }.count
        return HStack(spacing: 10) {
            Button { detailExercise = exercise } label: {
                HStack(spacing: 12) {
                    ExerciseArt(kind: exercise.illustration).frame(width: 58, height: 58)
                        .background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
                    VStack(alignment: .leading, spacing: 5) {
                        Text(exercise.name).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                        Text(exercise.muscle).font(.caption).foregroundStyle(.secondary)
                        if !equipment.isEmpty { Text(equipment).font(.caption2).foregroundStyle(.secondary) }
                        if count > 0 { Text("В тренировке: \(count)").font(.caption2).foregroundStyle(Color.gymLime) }
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "info.circle").font(.caption).foregroundStyle(Color.gymMuted)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityHint("Открыть мышцы, технику и видео")
            Button {
                add(exercise)
                addedCount += 1
            } label: {
                VStack(spacing: 4) {
                    Image(systemName: count == 0 ? "plus.circle.fill" : "plus.circle").font(.title2)
                    if count > 0 { Text("Ещё").font(.caption2) }
                }.frame(minWidth: 44, minHeight: 44)
            }.buttonStyle(.plain).foregroundStyle(Color.gymLime)
                .accessibilityLabel(count == 0 ? "Добавить: \(exercise.name)" : "Добавить ещё раз: \(exercise.name)")
        }.padding(.vertical, 4)
    }
}

private struct CustomExerciseEditor: View {
    var add: (Exercise) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var muscle = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Название", text: $name)
                    TextField("Группа мышц (необязательно)", text: $muscle)
                } footer: {
                    Text("Своё упражнение можно добавить в программу и отслеживать. Пока у него нет разметки основных и вспомогательных мышц, оно не включается в расчёт нагрузки.")
                }
            }
            .navigationTitle("Своё упражнение")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Добавить") {
                        let muscle = muscle.trimmingCharacters(in: .whitespacesAndNewlines)
                        add(Exercise(name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                                     muscle: muscle.isEmpty ? "Своё упражнение" : muscle,
                                     illustration: "curl", cue: "Записывай рабочий вес и количество повторений в каждом подходе."))
                        dismiss()
                    }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }.tint(.gymLime).preferredColorScheme(.dark)
    }
}
