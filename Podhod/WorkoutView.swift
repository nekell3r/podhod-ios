import SwiftUI

struct WorkoutView: View {
    @Bindable var store: WorkoutStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showFinish = false
    @State private var showDiscard = false
    @State private var stoppingSession: WorkoutSession?
    @State private var summary: WorkoutSession?
    @State private var detailExercise: Exercise?
    @State private var historyExercise: Exercise?
    @State private var settingsSession: WorkoutSession?
    @State private var showExerciseList = false
    @State private var setToRemove: UUID?
    @FocusState private var inputFocused: Bool

    var body: some View {
        NavigationStack {
            Group {
                if let summary {
                    completion(summary)
                } else if let session = store.archive.active {
                    training(session)
                } else {
                    ContentUnavailableView("Тренировка не начата", systemImage: "dumbbell", description: Text("Открой программу и выбери тренировку."))
                }
            }
            .background(Color.gymBackground)
            .navigationTitle("Тренировка")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            #if os(iOS)
            .toolbarBackground(Color.gymBackground, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(summary == nil ? "Свернуть" : "Готово") { dismiss() }.foregroundStyle(Color.gymMuted)
                }
                if summary == nil, store.archive.active != nil {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            inputFocused = false
                            stoppingSession = store.archive.active
                            showFinish = true
                        } label: { Label("Остановить", systemImage: "stop.circle") }
                            .font(.subheadline.weight(.semibold)).tint(.red)
                            .accessibilityHint("Сохранить выполненные подходы или отменить тренировку без записи")
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Menu {
                            if let session = store.archive.active {
                                let exercise = session.exercises[session.currentExercise]
                                Button("Настроить отдых", systemImage: "slider.horizontal.3") {
                                    inputFocused = false
                                    settingsSession = session
                                }
                                if !exercise.isCompleted {
                                    Button(exercise.isSkipped ? "Вернуть упражнение" : "Пропустить упражнение") {
                                        inputFocused = false
                                        store.setExerciseSkipped(sessionID: session.id, exerciseID: exercise.id, isSkipped: !exercise.isSkipped)
                                    }
                                }
                            }
                            Button("Завершить досрочно") {
                                stoppingSession = store.archive.active
                                showFinish = true
                            }.disabled(store.archive.active?.completedSets == 0)
                            Button("Отменить тренировку", role: .destructive) {
                                stoppingSession = store.archive.active
                                showDiscard = true
                            }
                        } label: { Image(systemName: "ellipsis.circle") }
                    }
                }
                #if os(iOS)
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Готово") { inputFocused = false }
                }
                #endif
            }
            .confirmationDialog("Остановить тренировку?", isPresented: $showFinish, titleVisibility: .visible, presenting: stoppingSession) { session in
                if session.completedSets > 0 {
                    Button("Сохранить выполненное и завершить") {
                        guard store.archive.active?.id == session.id else {
                            store.errorMessage = "Активная тренировка уже изменилась. Проверь её перед остановкой."
                            return
                        }
                        finish(partial: true)
                    }
                }
                Button("Отменить без записи", role: .destructive) {
                    guard store.archive.active?.id == session.id else {
                        store.errorMessage = "Активная тренировка уже изменилась. Проверь её перед отменой."
                        return
                    }
                    if store.discardActive() { dismiss() }
                }
                Button("Продолжить тренировку", role: .cancel) {}
            } message: { session in
                Text(session.completedSets > 0
                     ? "Выполнено подходов: \(session.completedSets). Можно сохранить их в историю. При отмене без записи текущая тренировка и все её записи будут удалены."
                     : "Выполненных подходов пока нет. Отмена удалит текущую тренировку и введённые значения, не добавляя запись в историю.")
            }
            .confirmationDialog("Отменить тренировку без записи?", isPresented: $showDiscard, titleVisibility: .visible, presenting: stoppingSession) { session in
                Button("Отменить без записи", role: .destructive) {
                    guard store.archive.active?.id == session.id else {
                        store.errorMessage = "Активная тренировка уже изменилась. Проверь её перед отменой."
                        return
                    }
                    if store.discardActive() { dismiss() }
                }
                Button("Продолжить тренировку", role: .cancel) {}
            } message: { _ in Text("Текущая тренировка и все её записи будут удалены. История не пополнится.") }
            .alert("Проверь данные", isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) {
                Button("Понятно") { store.errorMessage = nil }
            } message: { Text(store.errorMessage ?? "") }
        }
        .tint(.gymLime).preferredColorScheme(.dark)
        .interactiveDismissDisabled(summary == nil)
        .sheet(item: $detailExercise) { exercise in ExerciseDetailView(exercise: exercise) }
        .sheet(item: $historyExercise) { exercise in ExerciseHistoryView(store: store, exercise: exercise) }
        .sheet(item: $settingsSession) { session in
            WorkoutRestSettings(store: store, sessionID: session.id, exercise: session.exercises[session.currentExercise])
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if summary == nil, let session = store.archive.active {
                VStack(spacing: 10) {
                    WorkoutRestBar(store: store)
                    if !inputFocused { workoutNavigation(session) }
                }.padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 8)
                    .background(Color.gymBackground).tint(.gymLime)
                    .overlay(alignment: .top) { Divider() }
            }
        }
    }

    private func training(_ session: WorkoutSession) -> some View {
        let exercise = session.exercises[session.currentExercise]
        return ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(session.title).font(.subheadline.weight(.semibold))
                        Spacer(minLength: 12)
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            Text(workoutTimeText(context.date.timeIntervalSince(session.startedAt)))
                                .font(.subheadline.monospacedDigit()).foregroundStyle(Color.gymMuted)
                                .accessibilityLabel("Время тренировки")
                        }
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Записано \(session.completedSets) из \(session.totalSets) подходов")
                            Spacer()
                            if session.skippedSets > 0 { Text("Пропущено: \(session.skippedSets)") }
                        }.font(.caption).foregroundStyle(Color.gymMuted)
                        SwiftUI.ProgressView(value: Double(session.completedSets + session.skippedSets), total: Double(max(1, session.totalSets)))
                            .tint(.gymLime).accessibilityLabel("Разобрано подходов")
                    }
                    exerciseOverview(session)
                    HStack(alignment: .top, spacing: 14) {
                        ExerciseArt(kind: ExerciseCatalog.bundled.illustration(for: exercise.exercise))
                            .frame(width: 64, height: 64)
                            .background(Color.gymCard, in: RoundedRectangle(cornerRadius: 16))
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 6) {
                            Text(exercise.exercise.name).font(.title2.bold())
                                .fixedSize(horizontal: false, vertical: true)
                            Text("\(exercise.exercise.muscle) · \(session.currentExercise + 1) из \(session.exercises.count)")
                                .font(.subheadline).foregroundStyle(Color.gymMuted)
                        }
                    }
                    HStack(spacing: 12) {
                        Button {
                            inputFocused = false
                            detailExercise = exercise.exercise
                        } label: {
                            Label("Техника", systemImage: "play.rectangle")
                                .frame(maxWidth: .infinity, minHeight: 44)
                        }
                        Button {
                            inputFocused = false
                            historyExercise = exercise.exercise
                        } label: {
                            Label("История", systemImage: "clock.arrow.circlepath")
                                .frame(maxWidth: .infinity, minHeight: 44)
                        }
                    }.font(.subheadline.weight(.semibold)).buttonStyle(.bordered).tint(.gymLime)
                    if !exercise.exercise.cue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        DisclosureGroup("Подсказка к упражнению") {
                            Text(exercise.exercise.cue).font(.subheadline).foregroundStyle(Color.gymMuted)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
                        }.font(.subheadline)
                    }
                    if exercise.isSkipped {
                        VStack(alignment: .leading, spacing: 10) {
                            Label("Упражнение пропущено", systemImage: "forward.end").font(.headline)
                            Text("Подходы и введённые значения сохранены.")
                                .font(.subheadline).foregroundStyle(Color.gymMuted)
                            Button("Вернуть упражнение") {
                                store.setExerciseSkipped(sessionID: session.id, exerciseID: exercise.id, isSkipped: false)
                            }.frame(minHeight: 44)
                        }.frame(maxWidth: .infinity, alignment: .leading).modifier(GymCard())
                    }
                    VStack(spacing: 12) {
                        SectionLabel(title: "Подходы", detail: "Цель: \(exercise.targetReps)")
                        HStack(spacing: 8) {
                            Text("№").frame(width: 44)
                            Text("Вес, кг").frame(maxWidth: .infinity)
                            Text("Повторы").frame(maxWidth: .infinity)
                            Text("Запас").frame(width: 44)
                            Image(systemName: "checkmark").frame(width: 44)
                        }.font(.caption).foregroundStyle(Color.gymMuted).padding(.horizontal, 10)
                            .accessibilityHidden(true)
                        ForEach(Array(exercise.sets.enumerated()), id: \.element.id) { index, set in
                            setRow(set, index: index, exercise: exercise, sessionID: session.id)
                        }
                        Button {
                            inputFocused = false
                            store.addActiveSet(sessionID: session.id, exerciseID: exercise.id)
                        } label: {
                            Label("Добавить подход", systemImage: "plus.circle")
                                .frame(maxWidth: .infinity, minHeight: 44)
                        }.buttonStyle(.bordered).tint(.gymLime)
                            .disabled(exercise.isSkipped || exercise.sets.count >= 12)
                            .accessibilityHint("Изменяет только текущую тренировку. Максимум 12 подходов.")
                    }
                    DisclosureGroup("Как записывать подходы") {
                        Text("Для собственного веса укажи 0 кг. Галочка сохраняет выполненный подход. Запас — сколько повторов ещё получилось бы с той же техникой: 0 — в отказ, 5+ — пять или больше. Оценку можно менять до завершения тренировки.")
                            .font(.subheadline).foregroundStyle(Color.gymMuted).padding(.top, 8)
                    }.font(.subheadline)
                    Button {
                        inputFocused = false
                        settingsSession = session
                    } label: {
                        Label("Отдых: \(exercise.restSeconds) с / \(exercise.restAfterExerciseSeconds) с", systemImage: "slider.horizontal.3")
                            .font(.subheadline).frame(minHeight: 44)
                    }.buttonStyle(.plain).foregroundStyle(Color.gymLime)
                    Text("Все записи сохранены. Тренировку можно свернуть.")
                        .font(.caption).foregroundStyle(Color.gymMuted)
                }.padding(.horizontal, 20).padding(.vertical, 16).id("exercise-top")
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: session.currentExercise) { _, _ in
                if reduceMotion { proxy.scrollTo("exercise-top", anchor: .top) }
                else { withAnimation { proxy.scrollTo("exercise-top", anchor: .top) } }
            }
        }
    }

    private func exerciseOverview(_ session: WorkoutSession) -> some View {
        DisclosureGroup(isExpanded: $showExerciseList) {
            VStack(spacing: 0) {
                ForEach(Array(session.exercises.enumerated()), id: \.element.id) { index, item in
                    Button {
                        inputFocused = false
                        showExerciseList = false
                        store.selectExercise(index)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: item.isCompleted ? "checkmark.circle.fill" : item.isSkipped ? "forward.end.circle" : "circle")
                                .foregroundStyle(item.isCompleted || index == session.currentExercise ? Color.gymLime : .gymMuted)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.exercise.name).font(.subheadline.weight(.semibold))
                                Text("\(item.sets.filter(\.isCompleted).count) из \(item.sets.count) подходов\(item.isSkipped ? " · пропущено" : "")")
                                    .font(.caption).foregroundStyle(Color.gymMuted)
                            }
                            Spacer(minLength: 4)
                            if index == session.currentExercise {
                                Image(systemName: "location.fill").font(.caption).foregroundStyle(Color.gymLime)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 10)
                            .contentShape(Rectangle())
                    }.buttonStyle(.plain).foregroundStyle(.primary)
                        .accessibilityLabel("\(index + 1). \(item.exercise.name)")
                        .accessibilityValue(item.isCompleted ? "Выполнено" : item.isSkipped ? "Пропущено" : "Выполнено подходов: \(item.sets.filter(\.isCompleted).count) из \(item.sets.count)")
                }
            }.padding(.top, 8)
        } label: {
            HStack {
                Label("План тренировки", systemImage: "list.bullet")
                Spacer()
                Text("\(session.exercises.filter(\.isResolved).count) / \(session.exercises.count)")
                    .foregroundStyle(Color.gymMuted)
            }.font(.subheadline.weight(.semibold)).frame(minHeight: 44)
        }
    }

    private func workoutNavigation(_ session: WorkoutSession) -> some View {
        HStack(spacing: 12) {
            Button {
                inputFocused = false
                store.selectExercise(session.currentExercise - 1)
            } label: {
                Image(systemName: "chevron.left").font(.headline).frame(width: 44, height: 48)
            }.buttonStyle(.bordered).disabled(session.currentExercise == 0)
                .accessibilityLabel("Предыдущее упражнение")
            if session.isResolved {
                if session.completedSets > 0 {
                    Button { finish(partial: false) } label: {
                        Label("Завершить", systemImage: "checkmark").frame(maxWidth: .infinity)
                    }.buttonStyle(PrimaryButton())
                } else {
                    Button("Закрыть без записи") {
                        stoppingSession = session
                        showDiscard = true
                    }.buttonStyle(PrimaryButton())
                }
            } else if let next = session.exercises.indices.dropFirst(session.currentExercise + 1).first(where: { !session.exercises[$0].isResolved })
                ?? session.exercises.indices.prefix(session.currentExercise).first(where: { !session.exercises[$0].isResolved }) {
                Button {
                    inputFocused = false
                    store.selectExercise(next)
                } label: {
                    Label("Следующее упражнение", systemImage: "arrow.right").frame(maxWidth: .infinity)
                }.buttonStyle(PrimaryButton())
            } else {
                Button("Завершить тренировку") {
                    stoppingSession = session
                    showFinish = true
                }.buttonStyle(PrimaryButton()).disabled(session.completedSets == 0)
            }
        }
    }

    private func setRow(_ set: LoggedSet, index: Int, exercise: SessionExercise, sessionID: UUID) -> some View {
        let isLocked = set.isCompleted || exercise.isSkipped
        let hasEmptyField = set.weight.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
            set.reps.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Menu {
                    Button("Удалить незавершённый подход", systemImage: "trash", role: .destructive) {
                        inputFocused = false
                        setToRemove = set.id
                    }.disabled(isLocked || exercise.sets.count <= 1)
                } label: {
                    VStack(spacing: 2) {
                        Text("\(index + 1)").font(.headline.monospacedDigit())
                        Image(systemName: "ellipsis").font(.caption)
                    }.frame(width: 44, height: 48)
                }.buttonStyle(.plain).menuIndicator(.hidden)
                    .foregroundStyle(set.isCompleted ? Color.gymLime : .gymMuted)
                    .accessibilityLabel("Действия с подходом \(index + 1)")
                TextField("0", text: Binding(get: { set.weight }, set: { store.updateSet(exerciseID: exercise.id, setID: set.id, weight: $0) }))
                    .multilineTextAlignment(.center).textFieldStyle(.plain)
                    #if os(iOS)
                    .keyboardType(.decimalPad)
                    #endif
                    .focused($inputFocused).disabled(isLocked)
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
                    .accessibilityLabel("Вес в килограммах, подход \(index + 1)")
                TextField("—", text: Binding(get: { set.reps }, set: { store.updateSet(exerciseID: exercise.id, setID: set.id, reps: $0) }))
                    .multilineTextAlignment(.center).textFieldStyle(.plain)
                    #if os(iOS)
                    .keyboardType(.numberPad)
                    #endif
                    .focused($inputFocused).disabled(isLocked)
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
                    .accessibilityLabel("Повторы, подход \(index + 1)")
                Menu {
                    Picker("Запас повторений", selection: Binding(
                        get: { set.repsInReserve ?? .notRecorded },
                        set: { store.setRepetitionsInReserve(exerciseID: exercise.id, setID: set.id, reserve: $0) }
                    )) {
                        ForEach(RepetitionsInReserve.allCases) { reserve in Text(reserve.title).tag(reserve) }
                    }
                } label: {
                    Text((set.repsInReserve ?? .notRecorded).compactTitle)
                        .font(.body.monospacedDigit()).frame(width: 44, height: 48)
                        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
                }.buttonStyle(.plain).menuIndicator(.hidden)
                    .foregroundStyle(set.repsInReserve == nil || set.repsInReserve == .notRecorded ? Color.gymMuted : .gymLime)
                    .disabled(exercise.isSkipped)
                    .accessibilityLabel("Запас повторений, подход \(index + 1)")
                    .accessibilityValue((set.repsInReserve ?? .notRecorded).title)
                Button {
                    inputFocused = false
                    store.toggleSet(exerciseID: exercise.id, setID: set.id)
                } label: {
                    Image(systemName: set.isCompleted ? "checkmark.circle.fill" : exercise.isSkipped ? "forward.end.circle" : "circle")
                        .font(.title2).foregroundStyle(set.isCompleted ? Color.gymLime : .gymMuted)
                        .frame(width: 44, height: 48).contentShape(Rectangle())
                }.buttonStyle(.plain).disabled(exercise.isSkipped)
                    .accessibilityLabel(set.isCompleted ? "Изменить подход \(index + 1)" : exercise.isSkipped ? "Подход \(index + 1) пропущен" : "Записать подход \(index + 1)")
            }
            if let previous = store.previousSet(for: exercise.exercise, index: index) {
                if !isLocked && hasEmptyField {
                    Button {
                        inputFocused = false
                        store.reusePreviousSet(sessionID: sessionID, exerciseID: exercise.id, setID: set.id)
                    } label: {
                        HStack {
                            Text("Было: \(weightText(previous.weightValue ?? 0)) кг × \(previous.repValue ?? 0)")
                            Spacer(minLength: 8)
                            Image(systemName: "arrow.down.to.line")
                            Text("Подставить")
                        }.font(.caption).frame(minHeight: 44)
                    }.buttonStyle(.plain).foregroundStyle(Color.gymLime)
                        .accessibilityLabel("Подставить прошлый результат в пустые поля подхода \(index + 1)")
                } else {
                    Text("В прошлый раз: \(weightText(previous.weightValue ?? 0)) кг × \(previous.repValue ?? 0)")
                        .font(.caption).foregroundStyle(Color.gymMuted)
                }
            }
        }.padding(10).background(set.isCompleted ? Color.gymLime.opacity(0.055) : .gymCard, in: RoundedRectangle(cornerRadius: 16))
            .confirmationDialog("Удалить незавершённый подход?", isPresented: Binding(
                get: { setToRemove == set.id }, set: { if !$0 { setToRemove = nil } }
            ), titleVisibility: .visible) {
                Button("Удалить подход \(index + 1)", role: .destructive) {
                    store.removeActiveSet(sessionID: sessionID, exerciseID: exercise.id, setID: set.id)
                    setToRemove = nil
                }
                Button("Оставить", role: .cancel) { setToRemove = nil }
            } message: {
                Text("Введённые значения этого подхода будут удалены из текущей тренировки. Программа и история сохранятся.")
            }
    }

    private func finish(partial: Bool) {
        guard let sessionID = store.archive.active?.id else { return }
        if store.finish(allowPartial: partial) {
            summary = store.archive.history.first { $0.id == sessionID }
        }
    }

    private func completion(_ session: WorkoutSession) -> some View {
        ScrollView {
            VStack(spacing: 25) {
                Image(systemName: "checkmark.seal.fill").font(.system(size: 78)).foregroundStyle(Color.gymLime).padding(.top, 60)
                Text("Хорошая работа.").font(.system(size: 36, weight: .bold, design: .rounded))
                Text("\(session.title)\nТренировка сохранена в истории.")
                    .multilineTextAlignment(.center).foregroundStyle(Color.gymMuted).lineSpacing(6)
                VStack(spacing: 18) {
                    HStack { Text("Выполнено подходов"); Spacer(); Text("\(session.completedSets) / \(session.totalSets)").bold() }
                    if session.skippedSets > 0 {
                        HStack { Text("Пропущено подходов"); Spacer(); Text("\(session.skippedSets)").bold() }
                    }
                    Divider()
                    HStack { Text("Объём"); Spacer(); Text("\(weightText(session.volume)) кг").bold() }
                    Divider()
                    WorkoutTimingSummary(session: session)
                }.modifier(GymCard())
                if let totals = session.timingTotals() {
                    VStack(alignment: .leading, spacing: 14) {
                        SectionLabel(title: "По упражнениям")
                        ForEach(session.exercises) { exercise in
                            let time = totals.exercises[exercise.id] ?? WorkoutExerciseTimingTotals()
                            VStack(alignment: .leading, spacing: 5) {
                                Text(exercise.exercise.name).font(.subheadline.weight(.semibold))
                                Text("Учтено: \(workoutTimeText(time.exerciseSeconds)) · отдых \(workoutTimeText(time.restSeconds))")
                                    .font(.caption).foregroundStyle(Color.gymMuted)
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).modifier(GymCard())
                }
                Button("Готово") { dismiss() }.buttonStyle(PrimaryButton())
            }.padding(24)
        }
    }
}

private struct WorkoutRestBar: View {
    var store: WorkoutStore

    var body: some View {
        if let session = store.archive.active, let deadline = store.archive.restUntil {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let remaining = max(0, Int(ceil(deadline.timeIntervalSince(context.date))))
                VStack(spacing: 8) {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(remaining > 0 ? "Отдых" : "Можно продолжать").font(.subheadline.weight(.semibold))
                            Text(store.archive.restKind == .betweenExercises ? "Перед следующим упражнением" : "Между подходами")
                                .font(.caption).foregroundStyle(Color.gymMuted)
                        }
                        Spacer(minLength: 8)
                        Text(workoutTimeText(Double(remaining)))
                            .font(.title2.bold().monospacedDigit()).foregroundStyle(Color.gymLime)
                            .fixedSize(horizontal: true, vertical: false)
                            .accessibilityLabel("Осталось отдыха")
                            .accessibilityValue("\(remaining) секунд")
                    }
                    let adjustments = HStack(spacing: 10) {
                        Button("−30 с") {
                            store.adjustRest(sessionID: session.id, expectedDeadline: deadline, seconds: -30)
                        }.disabled(remaining == 0).accessibilityLabel("Уменьшить отдых на 30 секунд")
                        Button("+30 с") {
                            store.adjustRest(sessionID: session.id, expectedDeadline: deadline, seconds: 30)
                        }.disabled(remaining > 570).accessibilityLabel("Добавить 30 секунд отдыха")
                    }
                    let finish = Button(remaining > 0 ? "Закончить" : "Готово") {
                        store.stopRest(sessionID: session.id, expectedDeadline: deadline)
                    }
                        .accessibilityLabel("Закончить отдых")
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 10) { adjustments; Spacer(minLength: 0); finish }
                        VStack(alignment: .leading, spacing: 8) { adjustments; finish }
                    }.font(.subheadline.weight(.semibold)).buttonStyle(.bordered).controlSize(.large)
                }
            }
        }
    }
}

private struct WorkoutRestSettings: View {
    var store: WorkoutStore
    let sessionID: UUID
    let exercise: SessionExercise
    @Environment(\.dismiss) private var dismiss
    @State private var betweenSets: Int
    @State private var afterExercise: Int
    @State private var errorMessage: String?

    init(store: WorkoutStore, sessionID: UUID, exercise: SessionExercise) {
        self.store = store
        self.sessionID = sessionID
        self.exercise = exercise
        _betweenSets = State(initialValue: exercise.restSeconds)
        _afterExercise = State(initialValue: exercise.restAfterExerciseSeconds)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(exercise.exercise.name).font(.headline)
                    Stepper("Между подходами: \(betweenSets) с", value: $betweenSets, in: 0...600, step: 15)
                    Stepper("После упражнения: \(afterExercise) с", value: $afterExercise, in: 0...600, step: 15)
                } footer: {
                    Text("0 — без таймера. Настройки применятся после следующих подходов этой тренировки. Текущий отдых меняется кнопками −30/+30 на рабочем экране.")
                }
            }
            .navigationTitle("Отдых")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Сохранить") {
                        if store.updateActiveRest(sessionID: sessionID, exerciseID: exercise.id,
                            restSeconds: betweenSets, restAfterExerciseSeconds: afterExercise) {
                            dismiss()
                        } else {
                            errorMessage = store.errorMessage ?? "Тренировка или упражнение уже изменились. Закрой настройки и открой их заново."
                        }
                    }
                }
            }
            .alert("Не удалось сохранить", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("Понятно") { errorMessage = nil }
            } message: { Text(errorMessage ?? "") }
        }.tint(.gymLime).preferredColorScheme(.dark)
        #if os(macOS)
        .frame(minWidth: 430, minHeight: 400)
        #endif
    }
}

struct WorkoutTimingSummary: View {
    var session: WorkoutSession

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            LabeledContent("Всего", value: workoutTimeText(session.duration))
            if let totals = session.timingTotals() {
                LabeledContent("На упражнениях", value: workoutTimeText(totals.exerciseSeconds))
                LabeledContent("Отдых", value: workoutTimeText(totals.restSeconds))
                LabeledContent("Переходы и прочее", value: workoutTimeText(totals.otherSeconds))
                if totals.untrackedSeconds > 0.001 {
                    LabeledContent("Не измерялось", value: workoutTimeText(totals.untrackedSeconds))
                    Text("Часть времени до начала учёта или восстановления не распределена по упражнениям.")
                        .font(.caption).foregroundStyle(Color.gymMuted)
                }
                Text("Автоматический учёт: время на упражнении включает подготовку, а не только выполнение повторений.")
                    .font(.caption).foregroundStyle(Color.gymMuted).lineSpacing(3)
            } else {
                Text("Разбиение времени не измерялось в этой тренировке.")
                    .font(.caption).foregroundStyle(Color.gymMuted)
            }
        }
    }
}
