import SwiftUI

struct TrainingCycleView: View {
    var store: WorkoutStore
    @Environment(\.dismiss) private var dismiss
    @State private var showBuilder = false
    @State private var editing: CycleDaySelection?
    @State private var removing: TrainingCycleDocument?

    private struct CycleDaySelection: Identifiable {
        var id = UUID()
        var cycleID: UUID
        var weekID: UUID
        var day: TrainingDay
    }

    var body: some View {
        NavigationStack {
            List {
                if let plan = store.cycleState.document.plan {
                    Section {
                        LabeledContent("Начало", value: plan.startWeek)
                        LabeledContent("Продолжительность", value: "\(plan.weeks.count) недель")
                        LabeledContent("Повторение", value: plan.repeats ? "По кругу" : "Один цикл")
                        Text("\(plan.timezone) · Пропуски не сдвигают недели и не увеличивают нагрузку.")
                            .font(.caption).foregroundStyle(.secondary)
                    } header: { Text("Текущий цикл") }
                    ForEach(Array(plan.weeks.enumerated()), id: \.element.id) { index, week in
                        Section {
                            ForEach(week.days) { day in
                                Button {
                                    editing = CycleDaySelection(cycleID: plan.id, weekID: week.id, day: day)
                                } label: {
                                    HStack(alignment: .top, spacing: 12) {
                                        Text(day.shortName).font(.subheadline.bold()).foregroundStyle(Color.gymLime).frame(width: 32)
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(day.exercises.isEmpty ? "Отдых" : (day.title.isEmpty ? "Тренировка" : day.title))
                                                .foregroundStyle(.primary)
                                            if !day.exercises.isEmpty {
                                                Text("\(day.exercises.count) упр. · \(day.setCount) подх.")
                                                    .font(.caption).foregroundStyle(.secondary)
                                            }
                                            if let context = day.context, !context.summary.isEmpty {
                                                Text(context.summary).font(.caption).foregroundStyle(.secondary)
                                            }
                                        }
                                        Spacer(minLength: 0)
                                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                                    }.padding(.vertical, 5)
                                }.accessibilityLabel("Неделя \(index + 1), \(day.name), изменить")
                            }
                        } header: { Text("Неделя \(index + 1)") }
                    }
                    Section {
                        Button("Собрать цикл заново", systemImage: "arrow.triangle.2.circlepath") { showBuilder = true }
                        Button("Отключить цикл", role: .destructive) { removing = store.cycleState.document }
                    } footer: {
                        Text("Изменения используются только для ещё не созданных недель. Недели по датам, начатая тренировка и история сохраняют свои снимки. После отключения новые недели снова берутся из шаблона.")
                    }
                } else {
                    Section {
                        ContentUnavailableView("Свой ритм на несколько недель", systemImage: "calendar",
                            description: Text("Собери 2–12 недель из текущего шаблона, чередуй нагрузку и добавь разгрузку. Перед применением увидишь весь план."))
                        Button("Создать цикл", systemImage: "plus") { showBuilder = true }
                            .disabled(store.archive.week.allSatisfy { $0.exercises.isEmpty })
                        if store.archive.week.allSatisfy({ $0.exercises.isEmpty }) {
                            Text("Сначала добавь тренировку в шаблон недели.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Цикл тренировок")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Готово") { dismiss() } } }
            .sheet(isPresented: $showBuilder) { TrainingCycleBuilder(store: store) }
            .sheet(item: $editing) { selection in
                DayEditor(store: store, day: selection.day, destination: .cycle(cycleID: selection.cycleID, weekID: selection.weekID))
            }
            .confirmationDialog("Отключить цикл?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                                titleVisibility: .visible, presenting: removing) { original in
                Button("Отключить", role: .destructive) {
                    _ = store.saveTrainingCycle(nil, expected: original)
                    removing = nil
                }
                Button("Отмена", role: .cancel) { removing = nil }
            } message: { _ in Text("Созданные недели, текущая тренировка и история останутся. Новые недели будут создаваться из шаблона.") }
            .alert("Не удалось изменить цикл", isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) {
                Button("Понятно") { store.errorMessage = nil }
            } message: { Text(store.errorMessage ?? "") }
        }.tint(.gymLime).preferredColorScheme(.dark)
    }
}

private struct TrainingCycleBuilder: View {
    var store: WorkoutStore
    @Environment(\.dismiss) private var dismiss
    @State private var startDate: Date
    @State private var count = 4
    @State private var repeats = false
    @State private var generation: CycleGeneration = .repeatingTemplate
    @State private var preview: TrainingCyclePlan?
    @State private var error: String?
    private let original: TrainingCycleDocument
    private let template: [TrainingDay]

    init(store: WorkoutStore) {
        self.store = store
        original = store.cycleState.document
        template = store.archive.week
        let calendar = store.trainingCalendar
        let current = calendar.weekStart(containing: Date())
        _startDate = State(initialValue: calendar.calendar.date(byAdding: .day, value: 7, to: current) ?? current)
    }

    var body: some View {
        NavigationStack {
            Form {
                if let preview {
                    Section {
                        Text("С \(preview.startWeek) · \(preview.weeks.count) недель\(preview.repeats ? " · повторять" : "")")
                            .font(.headline)
                        Text("\(generation.title). Уже созданные недели сохраняются, даже если их даты попадают в цикл.")
                        Button("Изменить параметры") { self.preview = nil }
                    } header: { Text("Предпросмотр") }
                    ForEach(Array(preview.weeks.enumerated()), id: \.element.id) { number, week in
                        Section("Неделя \(number + 1)") {
                            ForEach(week.days.filter { !$0.exercises.isEmpty }) { day in
                                DisclosureGroup {
                                    ForEach(day.exercises) { plan in
                                        VStack(alignment: .leading, spacing: 5) {
                                            Text(plan.exercise.name)
                                            Text("\(plan.setCount) × \(plan.targetReps) · отдых \(plan.restSeconds) с")
                                                .font(.caption).foregroundStyle(.secondary)
                                        }.padding(.vertical, 4)
                                    }
                                } label: {
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text("\(day.shortName) · \(day.title.isEmpty ? "Тренировка" : day.title)")
                                        Text("\(day.setCount) подх.\(day.context.map { $0.loadType == .regular ? "" : " · \($0.loadType.title)" } ?? "")")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                    Section {
                        Button("Применить цикл") {
                            if store.saveTrainingCycle(preview, expected: original) { dismiss() }
                            else { error = store.errorMessage; store.errorMessage = nil }
                        }.font(.headline)
                    } footer: { Text("После применения можно изменить каждый день цикла отдельно. Фактические веса, повторы и запас не заполняются.") }
                } else {
                    Section("Параметры") {
                        DatePicker("Неделя начала", selection: $startDate, displayedComponents: .date)
                            .environment(\.timeZone, store.trainingCalendar.calendar.timeZone)
                        Text("Начало: \(store.trainingCalendar.dayKey(for: store.trainingCalendar.weekStart(containing: startDate))) — понедельник")
                            .font(.caption).foregroundStyle(.secondary)
                        Stepper("Недель: \(count)", value: $count, in: 2...12)
                        Toggle("Повторять цикл", isOn: $repeats)
                        Picker("Правило", selection: $generation) {
                            ForEach(CycleGeneration.allCases) { Text($0.title).tag($0) }
                        }.pickerStyle(.menu).accessibilityIdentifier("training.cycle.rule")
                    }
                    Section {
                        Text(generation.explanation).fixedSize(horizontal: false, vertical: true)
                        Text("Пропуски не сдвигают цикл. \(store.trainingCalendar.calendar.timeZone.identifier). Основа — шаблон на момент открытия этого экрана.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Section {
                        Button("Показать предпросмотр") {
                            do {
                                preview = try TrainingCyclePlan.generated(template: template,
                                    startWeek: store.trainingCalendar.dayKey(for: store.trainingCalendar.weekStart(containing: startDate)),
                                    timezone: store.trainingCalendar.calendar.timeZone.identifier, count: count,
                                    repeats: repeats, generation: generation)
                            } catch { self.error = error.localizedDescription }
                        }.font(.headline)
                    }
                }
            }
            .navigationTitle(preview == nil ? "Новый цикл" : "Проверить план")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } } }
            .alert("Проверь цикл", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("Понятно") { error = nil }
            } message: { Text(error ?? "") }
        }.tint(.gymLime).preferredColorScheme(.dark)
    }
}

struct WorkoutContextFields: View {
    @Binding var context: WorkoutPlanContext?
    var body: some View {
        Picker("Вариант", selection: Binding(get: { context?.variant ?? "" }, set: {
            var value = context ?? WorkoutPlanContext(); value.variant = $0; context = value
        })) {
            Text("Не задан").tag("")
            ForEach(["A", "B", "C"], id: \.self) { Text($0).tag($0) }
        }.pickerStyle(.menu).accessibilityIdentifier("training.context.variant")
        Picker("Тип дня", selection: Binding(get: { context?.loadType ?? .regular }, set: {
            var value = context ?? WorkoutPlanContext(); value.loadType = $0; context = value
        })) { ForEach(PlannedLoadType.allCases) { Text($0.title).tag($0) } }
            .pickerStyle(.menu).accessibilityIdentifier("training.context.load")
        Picker("Сложность", selection: Binding(get: { context?.difficulty ?? .unspecified }, set: {
            var value = context ?? WorkoutPlanContext(); value.difficulty = $0; context = value
        })) { ForEach(PlannedDifficulty.allCases) { Text($0.title).tag($0) } }
            .pickerStyle(.menu).accessibilityIdentifier("training.context.difficulty")
    }
}

struct PlannedSupersetSection: View {
    @Binding var day: TrainingDay
    @State private var selected: [UUID] = []
    @State private var restSeconds = 90
    @State private var error: String?

    private var available: [PlannedExercise] {
        let grouped = Set((day.supersets ?? []).flatMap(\.exerciseIDs))
        return day.exercises.filter { !grouped.contains($0.id) }
    }

    var body: some View {
        Section {
            ForEach(day.supersets ?? []) { group in
                VStack(alignment: .leading, spacing: 8) {
                    Text(group.exerciseIDs.compactMap { id in day.exercises.first { $0.id == id }?.exercise.name }.joined(separator: " → "))
                        .font(.subheadline.weight(.semibold))
                    Text("\(day.exercises.first { group.exerciseIDs.contains($0.id) }?.setCount ?? 0) кругов · отдых \(group.restSeconds) с")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Распустить группу", role: .destructive) { day.supersets?.removeAll { $0.id == group.id } }
                }.padding(.vertical, 4)
            }
            if available.count >= 2 {
                DisclosureGroup("Новый суперсет") {
                    ForEach(available) { plan in
                        Button {
                            if selected.contains(plan.id) { selected.removeAll { $0 == plan.id } }
                            else if selected.count < 4 { selected.append(plan.id) }
                        } label: {
                            HStack {
                                Text(plan.exercise.name).foregroundStyle(.primary)
                                Spacer()
                                if let position = selected.firstIndex(of: plan.id) {
                                    Text("\(position + 1)").foregroundStyle(Color.gymLime).accessibilityLabel("Порядок \(position + 1)")
                                } else { Image(systemName: "circle").foregroundStyle(.secondary) }
                            }.frame(minHeight: 44)
                        }
                    }
                    Stepper("Отдых между кругами: \(restSeconds) с", value: $restSeconds, in: 0...600, step: 15)
                    Button("Объединить выбранные") {
                        let members = available.filter { selected.contains($0.id) }
                        guard members.count == selected.count, Set(members.map(\.setCount)).count == 1 else {
                            error = "Задай одинаковое число подходов выбранным упражнениям."
                            return
                        }
                        day.supersets = (day.supersets ?? []) + [PlannedSuperset(exerciseIDs: selected, restSeconds: restSeconds)]
                        selected = []
                    }.disabled(!(2...4).contains(selected.count))
                }
            } else if (day.supersets ?? []).isEmpty {
                Text("Для суперсета нужны хотя бы два упражнения.").foregroundStyle(.secondary)
            }
        } header: { Text("Суперсеты") }
        footer: { Text("Выбирай 2–4 упражнения в порядке выполнения. Одинаковые подходы образуют круги с общим отдыхом. Изменение числа подходов участника меняет всю группу; удаление участника распускает её.") }
        .alert("Проверь группу", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("Понятно") { error = nil }
        } message: { Text(error ?? "") }
    }
}
