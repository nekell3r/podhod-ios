import SwiftUI
import Charts

struct ProgressViewScreen: View {
    var store: WorkoutStore
    @State private var selectedExerciseID: UUID?
    @State private var selectedSession: WorkoutSession?
    @State private var historyExercise: Exercise?
    private var exercises: [Exercise] {
        var seen: Set<UUID> = []
        return store.archive.history.flatMap(\.exercises).filter { $0.sets.contains(where: \.isCompleted) }
            .map(\.exercise).filter { seen.insert($0.id).inserted }.sorted { $0.name < $1.name }
    }
    private var selected: Exercise? { exercises.first { $0.id == selectedExerciseID } ?? exercises.first }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Твой прогресс").font(.system(size: 36, weight: .bold, design: .rounded))
                    Text("Маленькие шаги. Заметные изменения.").font(.subheadline).foregroundStyle(Color.gymMuted)
                }.padding(.top, 24)
                if store.archive.history.isEmpty {
                    VStack(alignment: .leading, spacing: 18) {
                        Image(systemName: "chart.xyaxis.line").font(.system(size: 50)).foregroundStyle(Color.gymLime).padding(.vertical, 16)
                        Text("Здесь будет твой рост").font(.system(.title2, design: .rounded).bold())
                        Text("Заверши первую тренировку — появятся история, рабочие веса и график по каждому упражнению.")
                            .font(.subheadline).foregroundStyle(Color.gymMuted).lineSpacing(4)
                    }.frame(maxWidth: .infinity, alignment: .leading).modifier(GymCard())
                } else {
                    HStack {
                        VStack(alignment: .leading, spacing: 7) {
                            Text("\(store.archive.history.count)").font(.system(size: 38, weight: .bold, design: .rounded)).foregroundStyle(Color.gymLime)
                            Text("Тренировки").font(.caption).foregroundStyle(Color.gymMuted)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 7) {
                            Text("\(store.archive.history.reduce(0) { $0 + $1.completedSets })")
                                .font(.system(size: 38, weight: .bold, design: .rounded))
                            Text("Записанные подходы").font(.caption).foregroundStyle(Color.gymMuted)
                        }
                    }.modifier(GymCard())
                    timeOverview
                    if let exercise = selected {
                        let points = store.progress(for: exercise)
                        VStack(alignment: .leading, spacing: 18) {
                            SectionLabel(title: "Рабочий вес", detail: "кг")
                            Menu {
                                ForEach(exercises) { item in
                                    Button(item.name) { selectedExerciseID = item.id }
                                }
                            } label: {
                                HStack {
                                    Text(exercise.name).font(.subheadline.bold()).multilineTextAlignment(.leading)
                                    Spacer()
                                    Image(systemName: "chevron.down").font(.caption)
                                }.foregroundStyle(Color.gymLime)
                            }.buttonStyle(.plain)
                            HStack(alignment: .firstTextBaseline, spacing: 7) {
                                Text(weightText(points.last?.weight ?? 0)).font(.system(size: 38, weight: .bold, design: .rounded))
                                Text("кг в последней тренировке").font(.caption).foregroundStyle(Color.gymMuted)
                            }
                            Chart {
                                ForEach(points, id: \.session.id) { point in
                                    LineMark(x: .value("Дата", point.session.startedAt), y: .value("Вес, кг", point.weight))
                                        .foregroundStyle(Color.gymLime).interpolationMethod(.linear)
                                    PointMark(x: .value("Дата", point.session.startedAt), y: .value("Вес, кг", point.weight))
                                        .foregroundStyle(Color.gymLime).symbolSize(50)
                                }
                            }
                            .chartYScale(domain: 0...max(10, (points.map(\.weight).max() ?? 0) * 1.2))
                            .chartXAxis { AxisMarks(values: .automatic(desiredCount: 3)) { _ in AxisValueLabel(format: .dateTime.day().month(.abbreviated)) } }
                            .chartYAxis { AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { _ in AxisGridLine().foregroundStyle(.white.opacity(0.06)); AxisValueLabel() } }
                            .frame(height: 180)
                            Text(points.count < 2 ? "Первая точка есть. После следующей тренировки сможешь сравнить результат." : "Максимальный вес выполненного подхода за тренировку. Сравнивай при схожем числе повторов.")
                                .font(.caption2).foregroundStyle(Color.gymMuted).lineSpacing(3)
                            Button {
                                historyExercise = exercise
                            } label: {
                                Label("Подходы и заметки по датам", systemImage: "clock.arrow.circlepath")
                                    .font(.subheadline.weight(.semibold)).frame(minHeight: 44)
                            }.buttonStyle(.plain).foregroundStyle(Color.gymLime)
                        }.modifier(GymCard())
                    }
                    VStack(spacing: 14) {
                        SectionLabel(title: "История", detail: "Записей: \(store.archive.history.count)")
                        ForEach(store.archive.history) { session in
                            Button { selectedSession = session } label: {
                                HStack(spacing: 16) {
                                    VStack(spacing: 2) {
                                        Text(session.startedAt.formatted(.dateTime.day())).font(.system(.title2, design: .rounded).bold())
                                        Text(session.startedAt.formatted(.dateTime.month(.abbreviated).locale(Locale(identifier: "ru_RU"))).uppercased()).font(.system(size: 9, weight: .bold))
                                    }.foregroundStyle(Color.gymLime).frame(width: 44)
                                    VStack(alignment: .leading, spacing: 7) {
                                        Text(session.title).font(.subheadline.bold()).foregroundStyle(.white)
                                        Text("\(session.completedSets) подх. · \(max(1, Int(session.duration / 60))) мин · \(weightText(session.volume)) кг")
                                            .font(.caption2).foregroundStyle(Color.gymMuted)
                                    }
                                    Spacer(minLength: 0)
                                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(Color.gymMuted)
                                }.modifier(GymCard())
                            }.buttonStyle(.plain)
                        }
                    }
                }
            }.padding(.horizontal, 22).padding(.bottom, 25)
        }
        .sheet(item: $selectedSession) { session in HistoryDetail(session: session) }
        .sheet(item: $historyExercise) { exercise in ExerciseHistoryView(store: store, exercise: exercise) }
    }

    private var timeOverview: some View {
        let history = store.archive.history
        let measured = history.compactMap { $0.timingTotals() }
        let elapsed = history.reduce(0) { $0 + max(0, $1.duration) }
        let unknown = history.reduce(0) { $0 + ($1.timingTotals()?.untrackedSeconds ?? max(0, $1.duration)) }
        return VStack(alignment: .leading, spacing: 14) {
            SectionLabel(title: "Время в зале")
            LabeledContent("Всего", value: workoutTimeText(elapsed))
            LabeledContent("На упражнениях", value: workoutTimeText(measured.reduce(0) { $0 + $1.exerciseSeconds }))
            LabeledContent("Отдых", value: workoutTimeText(measured.reduce(0) { $0 + $1.restSeconds }))
            LabeledContent("Переходы и прочее", value: workoutTimeText(measured.reduce(0) { $0 + $1.otherSeconds }))
            if unknown > 0.001 { LabeledContent("Не измерялось", value: workoutTimeText(unknown)) }
            Text("Время на упражнении включает подготовку. Для старых тренировок разбиение не измерялось.")
                .font(.caption).foregroundStyle(Color.gymMuted).lineSpacing(3)
        }.font(.subheadline).modifier(GymCard())
    }
}

struct HistoryDetail: View {
    var session: WorkoutSession
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("Дата", value: session.startedAt.formatted(.dateTime.day().month().year().locale(Locale(identifier: "ru_RU"))))
                    LabeledContent("Выполнено подходов", value: "\(session.completedSets) из \(session.totalSets)")
                    if session.skippedSets > 0 { LabeledContent("Пропущено подходов", value: "\(session.skippedSets)") }
                    LabeledContent("Объём", value: "\(weightText(session.volume)) кг")
                }
                Section("Время тренировки") {
                    WorkoutTimingSummary(session: session).padding(.vertical, 6)
                }
                ForEach(session.exercises) { item in
                    Section(item.exercise.name) {
                        if let totals = session.timingTotals() {
                            let time = totals.exercises[item.id] ?? WorkoutExerciseTimingTotals()
                            Text("Учтено: \(workoutTimeText(time.exerciseSeconds)) · отдых \(workoutTimeText(time.restSeconds))")
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                            Text("Время упражнения не измерялось").font(.caption).foregroundStyle(.secondary)
                        }
                        ForEach(Array(item.sets.enumerated()), id: \.element.id) { index, set in
                            HStack {
                                Text("Подход \(index + 1)").foregroundStyle(.secondary)
                                Spacer()
                                if set.isCompleted {
                                    VStack(alignment: .trailing, spacing: 4) {
                                        Text("\(weightText(set.weightValue ?? 0)) кг × \(set.repValue ?? 0)")
                                        if let reserve = set.repsInReserve, reserve != .notRecorded {
                                            Text(reserve.summary).font(.caption).foregroundStyle(Color.gymMuted)
                                        }
                                    }
                                    Image(systemName: "checkmark").foregroundStyle(Color.gymLime)
                                } else { Text(item.isSkipped ? "Пропущен" : "Не выполнен").foregroundStyle(.secondary) }
                            }.font(.subheadline)
                        }
                    }
                }
            }
            .navigationTitle(session.title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Готово") { dismiss() } } }
        }.tint(.gymLime).preferredColorScheme(.dark)
        #if os(macOS)
        .frame(minWidth: 430, minHeight: 650)
        #endif
    }
}

struct ExerciseHistoryView: View {
    var store: WorkoutStore
    var exercise: Exercise
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let history = store.exerciseHistory(for: exercise)
        let points = store.progress(for: exercise)
        NavigationStack {
            List {
                Section {
                    Text(exercise.name).font(.title2.bold())
                    Text("Выполненные подходы по датам. Заметки сохранены такими, какими были во время тренировки.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                if history.isEmpty {
                    ContentUnavailableView("Пока нет записей", systemImage: "clock.arrow.circlepath",
                        description: Text("Запиши подход и заверши тренировку — результат появится здесь."))
                } else {
                    Section("Максимальный рабочий вес · кг") {
                        Chart {
                            ForEach(points, id: \.session.id) { point in
                                LineMark(x: .value("Дата", point.session.startedAt), y: .value("Вес, кг", point.weight))
                                    .foregroundStyle(Color.gymLime)
                                PointMark(x: .value("Дата", point.session.startedAt), y: .value("Вес, кг", point.weight))
                                    .foregroundStyle(Color.gymLime)
                                    .accessibilityLabel(point.session.startedAt.formatted(.dateTime.day().month().year()))
                                    .accessibilityValue("\(weightText(point.weight)) кг")
                            }
                        }
                        .chartYScale(domain: 0...max(10, (points.map(\.weight).max() ?? 0) * 1.2))
                        .chartXAxis { AxisMarks(values: .automatic(desiredCount: 3)) { _ in AxisValueLabel(format: .dateTime.day().month(.abbreviated)) } }
                        .frame(height: 180).padding(.vertical, 8)
                        Text("Сравнивай вес при схожем числе повторов и запасе. Для собственного веса здесь будет 0 кг.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(history, id: \.session.id) { entry in
                        Section(entry.session.startedAt.formatted(.dateTime.day().month(.wide).year().locale(Locale(identifier: "ru_RU")))) {
                            Text(entry.session.title).font(.subheadline.weight(.semibold))
                            ForEach(entry.exercises) { item in
                                ForEach(Array(item.sets.enumerated()).filter { $0.element.isCompleted }, id: \.element.id) { index, set in
                                    completedSetRow(set, number: index + 1)
                                }
                                if !item.exercise.cue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text("Заметка к упражнению").font(.caption).foregroundStyle(.secondary)
                                        Text(item.exercise.cue).font(.subheadline)
                                    }.padding(.vertical, 4)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("История упражнения")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Готово") { dismiss() } } }
        }.tint(.gymLime).preferredColorScheme(.dark)
        #if os(macOS)
        .frame(minWidth: 430, minHeight: 650)
        #endif
    }

    private func completedSetRow(_ set: LoggedSet, number: Int) -> some View {
        let result = "\(weightText(set.weightValue ?? 0)) кг × \(set.repValue ?? 0)"
        return VStack(alignment: .leading, spacing: 6) {
            ViewThatFits(in: .horizontal) {
                HStack {
                    Text("Подход \(number)").foregroundStyle(.secondary)
                    Spacer()
                    Text(result).fontWeight(.semibold)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Подход \(number)").foregroundStyle(.secondary)
                    Text(result).fontWeight(.semibold)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            Text((set.repsInReserve ?? .notRecorded).summary)
                .font(.caption).foregroundStyle(.secondary)
        }.font(.subheadline).padding(.vertical, 4)
    }
}
