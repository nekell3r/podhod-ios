import SwiftUI

struct TodayView: View {
    var store: WorkoutStore
    var start: () -> Void
    var openProgram: () -> Void
    var openAccount: () -> Void
    var syncStatus: String
    var protein: ProteinTracker
    var reminders: ProteinReminders
    @State private var showEditor = false
    @State private var showStop = false
    @State private var stoppingSession: WorkoutSession?
    @State private var detailExercise: Exercise?
    private var day: TrainingDay { store.today }
    private var isEmpty: Bool { store.archive.week.allSatisfy { $0.exercises.isEmpty } && (store.archive.scheduledWeeks ?? []).allSatisfy { $0.workouts.isEmpty } }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { _ in
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    HStack {
                        HStack(spacing: 7) {
                            Image(systemName: "dumbbell.fill").foregroundStyle(Color.gymLime)
                            Text("ПОДХОД").font(.system(.caption, design: .rounded).weight(.black)).tracking(3)
                        }
                        Spacer()
                        Text(Date.now.formatted(.dateTime.day().month(.abbreviated).locale(Locale(identifier: "ru_RU"))))
                            .font(.caption).foregroundStyle(Color.gymMuted)
                        Button(action: openAccount) {
                            Image(systemName: "person.crop.circle").font(.title2).foregroundStyle(Color.gymLime)
                                .frame(width: 40, height: 44)
                        }.buttonStyle(.plain).accessibilityLabel("Аккаунт и синхронизация")
                    }.padding(.top, 14)
                    VStack(alignment: .leading, spacing: 7) {
                        Text("Сегодня").font(.system(size: 42, weight: .bold, design: .rounded))
                        Text(day.name + ". Твой темп, твой прогресс.").font(.subheadline).foregroundStyle(Color.gymMuted)
                    }
                    weekStrip
                    Button(action: openAccount) {
                        Label(syncStatus, systemImage: "icloud").font(.caption).foregroundStyle(Color.gymMuted)
                    }.buttonStyle(.plain)
                    if let active = store.archive.active {
                        VStack(alignment: .leading, spacing: 16) {
                            HStack(alignment: .firstTextBaseline, spacing: 12) {
                                Label("ТРЕНИРОВКА В ПРОЦЕССЕ", systemImage: "circle.fill")
                                    .font(.system(size: 10, weight: .bold)).tracking(1).foregroundStyle(Color.gymLime)
                                Spacer(minLength: 0)
                                Button {
                                    stoppingSession = active
                                    showStop = true
                                } label: { Label("Остановить", systemImage: "stop.circle") }
                                    .font(.caption.weight(.semibold)).foregroundStyle(.red)
                                    .frame(minHeight: 44)
                                    .accessibilityHint("Сохранить выполненные подходы или отменить тренировку без записи")
                            }
                            Text(active.title).font(.system(.title, design: .rounded).bold())
                            Text("Записано \(active.completedSets) из \(active.totalSets) подходов")
                                .font(.subheadline).foregroundStyle(Color.gymMuted)
                            Button(action: start) { Label("Продолжить тренировку", systemImage: "play.fill") }.buttonStyle(PrimaryButton())
                        }.modifier(GymCard())
                    } else if isEmpty {
                        onboarding
                    } else if !day.exercises.isEmpty {
                        workoutCard
                    } else {
                        restCard
                    }
                    ProteinTodayCard(tracker: protein, reminders: reminders)
                    if !day.exercises.isEmpty {
                        VStack(spacing: 12) {
                            SectionLabel(title: "План на сегодня", detail: "Упражнений: \(day.exercises.count)")
                            VStack(spacing: 2) {
                                ForEach(Array(day.exercises.enumerated()), id: \.element.id) { index, exercise in
                                    Button { detailExercise = exercise.exercise } label: {
                                        ExerciseRow(plan: exercise, number: index + 1)
                                    }.buttonStyle(.plain)
                                        .accessibilityHint("Открыть мышцы, технику и видео упражнения")
                                    if index < day.exercises.count - 1 { Divider().overlay(.white.opacity(0.03)) }
                                }
                            }.modifier(GymCard())
                            Button("Изменить тренировку") { showEditor = true }.font(.subheadline).foregroundStyle(Color.gymMuted).padding(.top, 4)
                        }
                    }
                    if !store.archive.history.isEmpty {
                        HStack(spacing: 0) {
                            stat(value: "\(store.archive.history.count)", label: "Тренировки")
                            Spacer()
                            stat(value: "\(store.archive.history.reduce(0) { $0 + $1.completedSets })", label: "Подходы")
                            Spacer()
                            stat(value: weightText(store.archive.history.reduce(0) { $0 + $1.volume } / 1000), label: "Объём, т")
                        }.modifier(GymCard())
                    }
                    Text("Каждый записанный подход — шаг вперёд.")
                        .font(.caption).foregroundStyle(Color.gymMuted).frame(maxWidth: .infinity).padding(.bottom, 16)
                }.padding(.horizontal, 22)
            }
        }
        .task { store.ensureWeek(containing: Date()) }
        .sheet(isPresented: $showEditor) { DayEditor(store: store, day: day, scheduledDate: Date()) }
        .sheet(item: $detailExercise) { exercise in ExerciseDetailView(exercise: exercise) }
        .confirmationDialog("Остановить тренировку?", isPresented: $showStop, titleVisibility: .visible, presenting: stoppingSession) { session in
            if session.completedSets > 0 {
                Button("Сохранить выполненное и завершить") {
                    guard store.archive.active?.id == session.id else {
                        store.errorMessage = "Активная тренировка уже изменилась. Проверь её перед остановкой."
                        return
                    }
                    store.finish(allowPartial: true)
                }
            }
            Button("Отменить без записи", role: .destructive) {
                guard store.archive.active?.id == session.id else {
                    store.errorMessage = "Активная тренировка уже изменилась. Проверь её перед отменой."
                    return
                }
                store.discardActive()
            }
            Button("Продолжить тренировку", role: .cancel) {}
        } message: { session in
            Text(session.completedSets > 0
                 ? "Выполнено подходов: \(session.completedSets). Можно сохранить их в историю. При отмене без записи текущая тренировка и все её записи будут удалены."
                 : "Выполненных подходов пока нет. Отмена удалит текущую тренировку и введённые значения, не добавляя запись в историю.")
        }
    }

    private var weekStrip: some View {
        HStack(spacing: 6) {
            ForEach(store.trainingCalendar.weekDates(containing: Date()).map { store.scheduledWeek(containing: $0).day(on: $0, calendar: store.trainingCalendar) }) { item in
                let selected = item.weekday == day.weekday
                VStack(spacing: 11) {
                    Text(item.shortName).font(.system(size: 10, weight: .bold))
                    Image(systemName: item.exercises.isEmpty ? "minus" : "dumbbell.fill").font(.system(size: 13, weight: .semibold))
                }.frame(maxWidth: .infinity).padding(.vertical, 15)
                    .foregroundStyle(selected ? Color.gymBackground : (item.exercises.isEmpty ? .gymMuted : .white))
                    .background(selected ? Color.gymLime : .gymCard, in: RoundedRectangle(cornerRadius: 17))
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(item.name), \(item.exercises.isEmpty ? "отдых" : "тренировка")\(selected ? ", сегодня" : "")")
            }
        }
    }

    private var workoutCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("ВРЕМЯ ДЛЯ СЕБЯ").font(.system(size: 10, weight: .bold)).tracking(2).foregroundStyle(Color.gymLime)
                Spacer()
                Image(systemName: "arrow.up.right").foregroundStyle(Color.gymLime)
            }
            Text(day.title.isEmpty ? "Твоя тренировка" : day.title).font(.system(size: 30, weight: .bold, design: .rounded))
            HStack(spacing: 18) {
                Label("\(day.exercises.count) упр.", systemImage: "dumbbell")
                Label("\(day.setCount) подх.", systemImage: "square.stack")
            }.font(.caption).foregroundStyle(Color.gymMuted)
            ExerciseArt(kind: day.exercises.first?.exercise.illustration ?? "bench")
                .frame(height: 155).padding(.vertical, -6)
            Button {
                if store.startScheduled(on: Date()) { start() }
            } label: { Label("Начать тренировку", systemImage: "play.fill") }.buttonStyle(PrimaryButton())
        }.modifier(GymCard())
    }

    private var onboarding: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("ТВОЯ ТОЧКА ОТСЧЁТА").font(.system(size: 10, weight: .bold)).tracking(2).foregroundStyle(Color.gymLime)
            Text("Сильнее.\nПодход за подходом.").font(.system(size: 30, weight: .bold, design: .rounded))
            ExerciseArt(kind: "bench").frame(height: 160)
            Text("Составь неделю тренировок. В зале останется только открыть «Сегодня» и записывать результат.")
                .font(.subheadline).foregroundStyle(Color.gymMuted).lineSpacing(4)
            Button(action: openProgram) { Label("Составить программу", systemImage: "plus") }.buttonStyle(PrimaryButton())
            Button("Взять пример на 3 дня") { store.loadExample() }
                .font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity).padding(.vertical, 8)
        }.modifier(GymCard())
    }

    private var restCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            Image(systemName: "leaf").font(.system(size: 36)).foregroundStyle(Color.gymLime)
            Text("День восстановления").font(.system(.title, design: .rounded).bold())
            Text("На сегодня упражнений нет. Отдых — тоже часть программы.").font(.subheadline).foregroundStyle(Color.gymMuted)
            if let next = nextDay {
                Text("Дальше: \(next.name.lowercased()) · \(next.title.isEmpty ? "тренировка" : next.title)")
                    .font(.caption).foregroundStyle(.white)
            }
            Button("Добавить тренировку на сегодня") { showEditor = true }.buttonStyle(PrimaryButton())
        }.modifier(GymCard())
    }

    private var nextDay: TrainingDay? {
        (1...7).compactMap { offset -> TrainingDay? in
            guard let date = store.trainingCalendar.calendar.date(byAdding: .day, value: offset, to: Date()) else { return nil }
            let day = store.scheduledWeek(containing: date).day(on: date, calendar: store.trainingCalendar)
            return day.exercises.isEmpty ? nil : day
        }.first
    }

    private func stat(value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(value).font(.system(.title2, design: .rounded).bold()).foregroundStyle(Color.gymLime)
            Text(label).font(.system(size: 10)).foregroundStyle(Color.gymMuted)
        }
    }
}
