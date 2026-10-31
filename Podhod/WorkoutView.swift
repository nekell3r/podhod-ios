import SwiftUI

struct WorkoutView: View {
    @Bindable var store: WorkoutStore
    @Environment(\.dismiss) private var dismiss
    @State private var showFinish = false
    @State private var showDiscard = false
    @State private var stoppingSession: WorkoutSession?
    @State private var summary: WorkoutSession?
    @State private var detailExercise: Exercise?
    @State private var historyExercise: Exercise?
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
    }

    private func training(_ session: WorkoutSession) -> some View {
        let exercise = session.exercises[session.currentExercise]
        return ScrollViewReader { proxy in
          ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack {
                    Text("ТРЕНИРОВКА").font(.system(size: 10, weight: .bold)).tracking(2).foregroundStyle(Color.gymLime)
                    Spacer()
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(Duration.seconds(max(0, context.date.timeIntervalSince(session.startedAt))).formatted(.time(pattern: .hourMinuteSecond)))
                            .font(.system(.caption, design: .monospaced)).foregroundStyle(Color.gymMuted)
                    }
                }
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text(session.title).font(.caption).foregroundStyle(Color.gymMuted)
                        Spacer()
                        Text("Выполнено: \(session.completedSets) / \(session.totalSets)").font(.caption).foregroundStyle(Color.gymLime)
                    }
                    SwiftUI.ProgressView(value: Double(session.completedSets + session.skippedSets), total: Double(max(1, session.totalSets))).tint(.gymLime)
                        .accessibilityLabel("Разобрано подходов")
                    if session.skippedSets > 0 {
                        Menu {
                            ForEach(session.exercises.filter(\.isSkipped)) { skipped in
                                Button("Вернуть: \(skipped.exercise.name)") {
                                    store.setExerciseSkipped(sessionID: session.id, exerciseID: skipped.id, isSkipped: false)
                                }
                            }
                        } label: {
                            Label("Пропущено подходов: \(session.skippedSets)", systemImage: "arrow.uturn.backward")
                                .font(.caption).foregroundStyle(Color.gymMuted)
                        }
                    }
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Array(session.exercises.enumerated()), id: \.element.id) { index, item in
                            Button { inputFocused = false; store.selectExercise(index) } label: {
                                HStack(spacing: 5) {
                                    if item.isCompleted { Image(systemName: "checkmark") }
                                    else if item.isSkipped { Image(systemName: "forward.end") }
                                    Text("\(index + 1)")
                                }.font(.caption.bold()).frame(minWidth: 35).padding(.vertical, 10)
                                    .foregroundStyle(index == session.currentExercise ? Color.gymBackground : .gymMuted)
                                    .background(index == session.currentExercise ? Color.gymLime : .gymCard, in: Capsule())
                            }.buttonStyle(.plain).accessibilityLabel("Упражнение \(index + 1): \(item.exercise.name)\(item.isCompleted ? ", выполнено" : item.isSkipped ? ", пропущено" : "")")
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 10) {
                    Text("\(exercise.exercise.muscle.uppercased()) / \(session.currentExercise + 1) ИЗ \(session.exercises.count)")
                        .font(.system(size: 10, weight: .bold)).tracking(2).foregroundStyle(Color.gymLime)
                    Text(exercise.exercise.name).font(.system(size: 31, weight: .bold, design: .rounded)).fixedSize(horizontal: false, vertical: true)
                    Button {
                        inputFocused = false
                        detailExercise = exercise.exercise
                    } label: {
                        VStack(spacing: 10) {
                            ExerciseArt(kind: ExerciseCatalog.bundled.illustration(for: exercise.exercise)).frame(height: 165)
                            Label("Мышцы, техника и видео", systemImage: "play.rectangle")
                                .font(.caption.weight(.semibold)).foregroundStyle(Color.gymLime)
                                .padding(.bottom, 14)
                        }.frame(maxWidth: .infinity).background(Color.gymCard, in: RoundedRectangle(cornerRadius: 24))
                    }.buttonStyle(.plain)
                        .accessibilityLabel("Мышцы, техника и видео: \(exercise.exercise.name)")
                    Text(exercise.exercise.cue).font(.caption).foregroundStyle(Color.gymMuted).lineSpacing(3)
                }
                if exercise.isSkipped {
                    VStack(alignment: .leading, spacing: 12) {
                        Label("Упражнение пропущено", systemImage: "forward.end").font(.headline)
                        Text("Выполненные подходы и введённые значения сохранены. Программа следующих тренировок не изменилась.")
                            .font(.caption).foregroundStyle(Color.gymMuted)
                        Button("Вернуть упражнение") {
                            store.setExerciseSkipped(sessionID: session.id, exerciseID: exercise.id, isSkipped: false)
                        }.font(.subheadline.bold())
                    }.modifier(GymCard())
                }
                if let until = store.archive.restUntil {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        let remaining = max(0, Int(ceil(until.timeIntervalSince(context.date))))
                        HStack(spacing: 12) {
                            Image(systemName: remaining > 0 ? "timer" : "checkmark.circle").font(.title2)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(remaining > 0
                                     ? (store.archive.restKind == .betweenExercises ? "Отдых перед следующим упражнением" : "Отдых между подходами")
                                     : (store.archive.restKind == .betweenExercises ? "Можно к следующему упражнению" : "Можно к следующему подходу"))
                                    .font(.caption.weight(.semibold))
                                Text(remaining > 0 ? String(format: "%d:%02d", remaining / 60, remaining % 60) : "Отдых завершён")
                                    .font(.system(.title2, design: .monospaced).bold())
                            }
                            Spacer()
                            Button(remaining > 0 ? "Пропустить" : "ОК") { store.stopRest() }.font(.caption.bold())
                        }.foregroundStyle(Color.gymLime).modifier(GymCard())
                    }
                }
                VStack(spacing: 12) {
                    SectionLabel(title: "Рабочие подходы", detail: "Цель: \(exercise.targetReps)")
                    HStack {
                        Text("ПОДХОД").frame(width: 50, alignment: .leading)
                        Text("КГ").frame(maxWidth: .infinity)
                        Text("ПОВТОРЫ").frame(maxWidth: .infinity)
                        Text("ГОТОВО").frame(width: 54)
                    }.font(.system(size: 9, weight: .bold)).tracking(1).foregroundStyle(Color.gymMuted)
                    ForEach(Array(exercise.sets.enumerated()), id: \.element.id) { index, set in
                        setRow(set, index: index, exercise: exercise)
                    }
                    Text("Собственный вес: укажи 0 кг. Отметь галочкой каждый выполненный подход.")
                        .font(.caption2).foregroundStyle(Color.gymMuted).frame(maxWidth: .infinity, alignment: .leading)
                    Text("Запас — сколько повторов ещё получилось бы с той же техникой. 0 — в отказ, 5+ — пять или больше. Указывать необязательно; оценку можно изменить до завершения тренировки.")
                        .font(.caption).foregroundStyle(Color.gymMuted).frame(maxWidth: .infinity, alignment: .leading)
                }
                if let previous = store.previousExercise(exercise.exercise) {
                    VStack(alignment: .leading, spacing: 8) {
                        Button {
                            inputFocused = false
                            historyExercise = exercise.exercise
                        } label: {
                            HStack {
                                Label("В прошлый раз", systemImage: "clock.arrow.circlepath")
                                Spacer()
                                Text("Вся история")
                                Image(systemName: "chevron.right")
                            }.font(.subheadline.weight(.semibold)).frame(minHeight: 44)
                        }.buttonStyle(.plain).foregroundStyle(Color.gymLime)
                            .accessibilityLabel("История и прогресс: \(exercise.exercise.name)")
                        Text(previous.sets.filter(\.isCompleted).map {
                            let result = "\(weightText($0.weightValue ?? 0)) кг × \($0.repValue ?? 0)"
                            return $0.repsInReserve.map { result + " · " + $0.summary } ?? result
                        }.joined(separator: "\n"))
                            .font(.caption).foregroundStyle(Color.gymMuted)
                    }.modifier(GymCard())
                }
                if session.isResolved {
                    if session.completedSets > 0 {
                        Button { finish(partial: false) } label: { Label("Завершить тренировку", systemImage: "checkmark") }.buttonStyle(PrimaryButton())
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
                    } label: { Label("Следующее упражнение", systemImage: "arrow.right") }.buttonStyle(PrimaryButton())
                } else {
                    Button("Завершить тренировку") {
                        stoppingSession = session
                        showFinish = true
                    }.buttonStyle(PrimaryButton()).disabled(session.completedSets == 0)
                }
                Text("Можно свернуть: все записи уже сохранены.").font(.caption2).foregroundStyle(Color.gymMuted).frame(maxWidth: .infinity)
            }.padding(.horizontal, 22).padding(.top, 15).padding(.bottom, 30)
                .id("exercise-top")
          }
          .scrollDismissesKeyboard(.interactively)
          .onChange(of: session.currentExercise) { _, _ in
              withAnimation { proxy.scrollTo("exercise-top", anchor: .top) }
          }
        }
    }

    private func setRow(_ set: LoggedSet, index: Int, exercise: SessionExercise) -> some View {
        VStack(spacing: 4) {
            HStack(spacing: 10) {
                Text(String(format: "%02d", index + 1)).font(.system(.headline, design: .monospaced))
                    .foregroundStyle(set.isCompleted ? Color.gymLime : .white).frame(width: 42, alignment: .leading)
                TextField("0", text: Binding(get: { set.weight }, set: { store.updateSet(exerciseID: exercise.id, setID: set.id, weight: $0) }))
                    .multilineTextAlignment(.center).textFieldStyle(.plain)
                    #if os(iOS)
                    .keyboardType(.decimalPad)
                    #endif
                    .focused($inputFocused).disabled(set.isCompleted || exercise.isSkipped)
                    .padding(.vertical, 13).frame(maxWidth: .infinity).background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
                    .accessibilityLabel("Вес в килограммах, подход \(index + 1)")
                TextField("—", text: Binding(get: { set.reps }, set: { store.updateSet(exerciseID: exercise.id, setID: set.id, reps: $0) }))
                    .multilineTextAlignment(.center).textFieldStyle(.plain)
                    #if os(iOS)
                    .keyboardType(.numberPad)
                    #endif
                    .focused($inputFocused).disabled(set.isCompleted || exercise.isSkipped)
                    .padding(.vertical, 13).frame(maxWidth: .infinity).background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
                    .accessibilityLabel("Повторы, подход \(index + 1)")
                Button {
                    inputFocused = false
                    store.toggleSet(exerciseID: exercise.id, setID: set.id)
                } label: {
                    Image(systemName: set.isCompleted ? "checkmark.circle.fill" : exercise.isSkipped ? "forward.end.circle" : "circle")
                        .font(.system(size: 29)).foregroundStyle(set.isCompleted ? Color.gymLime : .gymMuted)
                        .frame(width: 44, height: 48).contentShape(Rectangle())
                }.buttonStyle(.plain).disabled(exercise.isSkipped)
                    .accessibilityLabel(set.isCompleted ? "Изменить подход \(index + 1)" : exercise.isSkipped ? "Подход \(index + 1) пропущен" : "Записать подход \(index + 1)")
            }
            Menu {
                Picker("Запас повторений", selection: Binding(
                    get: { set.repsInReserve ?? .notRecorded },
                    set: { store.setRepetitionsInReserve(exerciseID: exercise.id, setID: set.id, reserve: $0) }
                )) {
                    ForEach(RepetitionsInReserve.allCases) { reserve in
                        Text(reserve.title).tag(reserve)
                    }
                }
            } label: {
                ViewThatFits(in: .horizontal) {
                    HStack {
                        Text("Запас повторений")
                        Spacer(minLength: 8)
                        Text((set.repsInReserve ?? .notRecorded).title)
                        Image(systemName: "chevron.up.chevron.down")
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Запас повторений")
                        Label((set.repsInReserve ?? .notRecorded).title, systemImage: "chevron.up.chevron.down")
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.font(.subheadline).frame(minHeight: 44).contentShape(Rectangle())
            }.buttonStyle(.plain).foregroundStyle(set.repsInReserve == nil || set.repsInReserve == .notRecorded ? Color.gymMuted : .gymLime)
                .disabled(exercise.isSkipped)
                .accessibilityLabel("Запас повторений, подход \(index + 1)")
                .accessibilityValue((set.repsInReserve ?? .notRecorded).title)
        }.padding(10).background(set.isCompleted ? Color.gymLime.opacity(0.055) : .gymCard, in: RoundedRectangle(cornerRadius: 18))
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
