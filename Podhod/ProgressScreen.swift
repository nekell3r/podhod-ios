import SwiftUI
import Charts

struct ProgressViewScreen: View {
    var store: WorkoutStore
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var period: WorkoutProgressPeriod = .month
    @State private var metric: ExerciseProgressMetric = .weight
    @State private var selectedExerciseID: UUID?
    @State private var selectedDate: Date?
    @State private var selectedSession: WorkoutSession?
    @State private var selectedRecord: WorkoutSetRecord?
    @State private var historyExercise: Exercise?

    private var exercises: [Exercise] {
        let catalog = ExerciseCatalog.bundled
        var seen: Set<UUID> = []
        return store.archive.history.flatMap(\.exercises).filter { $0.sets.contains { $0.isCompleted && $0.isValid } }
            .map { catalog.entry(for: $0.exercise.id)?.exercise ?? $0.exercise }
            .filter { seen.insert($0.id).inserted }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    private var selected: Exercise? { exercises.first { $0.id == selectedExerciseID } ?? exercises.first }

    var body: some View {
        let report = WorkoutProgressReport(history: store.archive.history, period: period, calendar: store.trainingCalendar)
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Твой прогресс").font(.system(.largeTitle, design: .rounded).bold())
                    Text("Тренировки, рабочие подходы и личные результаты.")
                        .font(.subheadline).foregroundStyle(Color.gymMuted)
                }.padding(.top, 24)
                Picker("Период прогресса", selection: $period) {
                    ForEach(WorkoutProgressPeriod.allCases) { Text($0.title).tag($0) }
                }.pickerStyle(.segmented)
                if store.archive.history.isEmpty {
                    ContentUnavailableView("Здесь будет твой рост", systemImage: "chart.xyaxis.line",
                        description: Text("Заверши первую тренировку — появятся история, рабочие веса и рекорды."))
                } else {
                    overview(report)
                    DisclosureGroup("Время в зале") {
                        timeOverview(report.current).padding(.top, 12)
                    }.font(.headline).tint(.gymLime).modifier(GymCard())
                    if let exercise = selected {
                        let progress = WorkoutExerciseProgress(sessions: report.current.sessions, exercise: exercise)
                        chartCard(exercise: exercise, progress: progress)
                        let allTime = WorkoutProgressReport(history: store.archive.history, period: .allTime, calendar: store.trainingCalendar)
                        recordsCard(WorkoutExerciseProgress(sessions: allTime.current.sessions, exercise: exercise))
                    }
                    history(report.current.sessions)
                }
            }.padding(.horizontal, 22).padding(.bottom, 25)
        }
        .onChange(of: period) { _, _ in selectedDate = nil }
        .onChange(of: metric) { _, _ in selectedDate = nil }
        .onChange(of: selectedExerciseID) { _, _ in selectedDate = nil }
        .sheet(item: $selectedSession) { HistoryDetail(session: $0, calendar: store.trainingCalendar) }
        .sheet(item: $selectedRecord) { HistoryDetail(session: $0.session, calendar: store.trainingCalendar, highlightedSetID: $0.id) }
        .sheet(item: $historyExercise) { ExerciseHistoryView(store: store, exercise: $0) }
    }

    private func overview(_ report: WorkoutProgressReport) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionLabel(title: "За период")
            if let interval = report.interval {
                Text("\(store.trainingCalendar.dayLabel(for: interval.start)) — \(store.trainingCalendar.dayLabel(for: interval.end.addingTimeInterval(-1)))")
                    .font(.subheadline).foregroundStyle(Color.gymMuted)
            }
            summaryRow("Тренировки", value: Double(report.current.sessions.count), previous: report.previous.map { Double($0.sessions.count) })
            summaryRow("Записанные подходы", value: Double(report.current.completedSets), previous: report.previous.map { Double($0.completedSets) })
            summaryRow("Повторы", value: Double(report.current.repetitions), previous: report.previous.map { Double($0.repetitions) })
            summaryRow("Объём, кг", value: report.current.volume, previous: report.previous?.volume)
            if report.current.bodyweightSets > 0 {
                Text("Подходов с записью 0 кг: \(report.current.bodyweightSets). Повторы учтены, килограммы собственного веса не добавляются в объём.")
                    .font(.caption).foregroundStyle(Color.gymMuted)
            }
            if let days = period.days {
                Text("По дате начала тренировки, включая сегодня. Сравнение — с предыдущими \(days) календарными днями. Плановые и незавершённые подходы не входят в результат.")
                    .font(.caption).foregroundStyle(Color.gymMuted)
            }
        }.modifier(GymCard())
    }

    private func summaryRow(_ title: String, value: Double, previous: Double?) -> some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6)) : AnyLayout(HStackLayout(alignment: .firstTextBaseline))
        return layout {
            Text(title).font(.subheadline)
            if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 12) }
            VStack(alignment: dynamicTypeSize.isAccessibilitySize ? .leading : .trailing, spacing: 4) {
                Text(weightText(value)).font(.title3.bold().monospacedDigit())
                if let previous {
                    let difference = ((value - previous) * 10).rounded() / 10
                    let change = difference == 0 ? "без изменений" : "\(difference > 0 ? "+" : "")\(weightText(difference))"
                    Text("Ранее \(weightText(previous)) · \(change)").font(.caption).foregroundStyle(Color.gymMuted)
                }
            }
        }
    }

    private func timeOverview(_ totals: WorkoutProgressSummary) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            LabeledContent("Всего", value: workoutTimeText(totals.elapsedSeconds))
            LabeledContent("На упражнениях", value: workoutTimeText(totals.exerciseSeconds))
            LabeledContent("Отдых", value: workoutTimeText(totals.restSeconds))
            LabeledContent("Переходы и прочее", value: workoutTimeText(totals.otherSeconds))
            if totals.untrackedSeconds > 0.001 { LabeledContent("Не измерялось", value: workoutTimeText(totals.untrackedSeconds)) }
            Text("Время на упражнении включает подготовку. Для старых тренировок разбиение остаётся неизвестным.")
                .font(.caption).foregroundStyle(Color.gymMuted)
        }.font(.subheadline)
    }

    private func chartCard(exercise: Exercise, progress: WorkoutExerciseProgress) -> some View {
        let points = progress.points.filter { metric.value(in: $0) != nil }
        let nearest = selectedDate.flatMap { date in
            points.min { abs($0.session.startedAt.timeIntervalSince(date)) < abs($1.session.startedAt.timeIntervalSince(date)) }
        }
        return VStack(alignment: .leading, spacing: 16) {
            SectionLabel(title: "По упражнению")
            Menu {
                ForEach(exercises) { item in
                    Button(item.name) { selectedExerciseID = item.id }
                }
            } label: {
                HStack {
                    Text(exercise.name).font(.headline).multilineTextAlignment(.leading)
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.down").font(.caption)
                }.frame(minHeight: 44)
            }.buttonStyle(.plain).foregroundStyle(Color.gymLime).accessibilityLabel("Выбрать упражнение: \(exercise.name)")
            Picker("Показатель графика", selection: $metric) {
                ForEach(ExerciseProgressMetric.allCases) { Text($0.title).tag($0) }
            }.pickerStyle(.segmented)
            if points.isEmpty {
                Text(metric == .reserve ? "В выбранном периоде нет выполненных подходов с оценкой запаса." : "В этом периоде нет выполненных подходов этого упражнения.")
                    .font(.subheadline).foregroundStyle(Color.gymMuted).padding(.vertical, 24)
            } else {
                Text(metric.unit).font(.caption).foregroundStyle(Color.gymMuted)
                progressChart(points: points, nearest: nearest)
                if let point = nearest ?? points.last, let value = metric.value(in: point) {
                    chartSelection(point: point, value: value, points: points)
                }
            }
            Text(metric.explanation).font(.caption).foregroundStyle(Color.gymMuted)
            Button { historyExercise = exercise } label: {
                Label("Подходы и заметки по датам", systemImage: "clock.arrow.circlepath").frame(minHeight: 44)
            }.buttonStyle(.plain).font(.subheadline.weight(.semibold)).foregroundStyle(Color.gymLime)
        }.modifier(GymCard())
    }

    private func progressChart(points: [ExerciseProgressPoint], nearest: ExerciseProgressPoint?) -> some View {
        let upper = metric == .reserve ? 5 : max(1, (points.compactMap { metric.value(in: $0) }.max() ?? 0) * 1.15)
        return Chart {
            ForEach(points) { point in
                if let value = metric.value(in: point) {
                    LineMark(x: .value("Дата", point.session.startedAt), y: .value(metric.title, value))
                        .foregroundStyle(Color.gymLime)
                    PointMark(x: .value("Дата", point.session.startedAt), y: .value(metric.title, value))
                        .foregroundStyle(Color.gymLime).symbolSize(45)
                        .accessibilityLabel(store.trainingCalendar.historyDayLabel(for: point.session.startedAt))
                        .accessibilityValue(metric == .reserve && value == 5 ? "5+ повторов в запасе" : "\(weightText(value)) \(metric.unit)")
                }
            }
            if let nearest {
                RuleMark(x: .value("Выбрано", nearest.session.startedAt)).foregroundStyle(Color.gymMuted.opacity(0.5))
            }
        }
        .chartYScale(domain: 0...upper)
        .chartXSelection(value: $selectedDate)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 3)) { value in
                AxisValueLabel(anchor: .topTrailing) {
                    if let date = value.as(Date.self) {
                        VStack(spacing: 2) {
                            Text(store.trainingCalendar.dayLabel(for: date))
                            if period == .allTime {
                                Text(String(store.trainingCalendar.calendar.component(.year, from: date)))
                            }
                        }.font(.caption2).fixedSize()
                    }
                }
            }
        }
        .chartYAxis {
            if metric == .reserve {
                AxisMarks(position: .leading, values: [0.0, 1, 2, 3, 4, 5]) { value in
                    AxisGridLine().foregroundStyle(.white.opacity(0.06))
                    AxisValueLabel {
                        if let number = value.as(Double.self) { Text(number == 5 ? "5+" : "\(Int(number))") }
                    }
                }
            } else {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { _ in
                    AxisGridLine().foregroundStyle(.white.opacity(0.06))
                    AxisValueLabel()
                }
            }
        }
        .environment(\.calendar, store.trainingCalendar.calendar)
        .environment(\.timeZone, store.trainingCalendar.calendar.timeZone)
        .frame(height: dynamicTypeSize.isAccessibilitySize ? 300 : 180)
    }

    private func chartSelection(point: ExerciseProgressPoint, value: Double, points: [ExerciseProgressPoint]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Menu {
                ForEach(points.reversed()) { item in
                    if let amount = metric.value(in: item) {
                        Button("\(store.trainingCalendar.historyDayLabel(for: item.session.startedAt)) · \(metric == .reserve && amount == 5 ? "5+" : weightText(amount)) \(metric.unit) · \(item.session.title)") {
                            selectedDate = item.session.startedAt
                        }
                    }
                }
            } label: {
                HStack(alignment: .firstTextBaseline) {
                    Text("\(store.trainingCalendar.historyDayLabel(for: point.session.startedAt)) · \(metric == .reserve && value == 5 ? "5+" : weightText(value)) \(metric.unit)")
                        .font(.headline).multilineTextAlignment(.leading)
                    Image(systemName: "chevron.down").font(.caption)
                }.frame(minHeight: 44)
            }.foregroundStyle(Color.gymLime).accessibilityLabel("Выбрать запись графика")
            Button { selectedSession = point.session } label: {
                Label("Открыть тренировку", systemImage: "arrow.right")
                    .font(.subheadline).frame(minHeight: 44)
            }.buttonStyle(.plain).foregroundStyle(Color.gymLime)
        }
    }

    private func recordsCard(_ progress: WorkoutExerciseProgress) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionLabel(title: "Рекорды за всё время")
            if let record = progress.bestWeight { recordRow("Максимальный вес", record: record) }
            if let record = progress.bestRepetitions { recordRow("Больше всего повторов в подходе", record: record) }
            if let record = progress.bestSetVolume { recordRow("Максимальный объём подхода", record: record) }
            if progress.bestWeight == nil {
                Text("Рекорд веса появится после выполненного подхода с весом больше 0 кг.")
                    .font(.caption).foregroundStyle(Color.gymMuted)
            }
            Text("Каждый результат относится к конкретному подходу. Учитывай вес, число повторов и запас вместе; нажми, чтобы открыть исходную запись.")
                .font(.caption).foregroundStyle(Color.gymMuted)
        }.modifier(GymCard())
    }

    private func recordRow(_ title: String, record: WorkoutSetRecord) -> some View {
        Button { selectedRecord = record } label: {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.caption).foregroundStyle(Color.gymMuted)
                Text("\(weightText(record.set.weightValue ?? 0)) кг × \(record.set.repValue ?? 0)").font(.headline)
                Text("\(store.trainingCalendar.historyDayLabel(for: record.session.startedAt)) · подход \(record.number)")
                    .font(.subheadline).foregroundStyle(Color.gymMuted)
                if let reserve = record.set.repsInReserve, reserve != .notRecorded {
                    Text(reserve.summary).font(.caption).foregroundStyle(Color.gymMuted)
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 6)
        }.buttonStyle(.plain).foregroundStyle(Color.gymLime)
    }

    private func history(_ sessions: [WorkoutSession]) -> some View {
        LazyVStack(alignment: .leading, spacing: 14) {
            SectionLabel(title: "История", detail: "Записей: \(sessions.count)")
            if sessions.isEmpty {
                Text("За выбранный период нет завершённых тренировок.").font(.subheadline).foregroundStyle(Color.gymMuted)
                Button("Показать всё время") { period = .allTime }.frame(minHeight: 44).foregroundStyle(Color.gymLime)
            }
            ForEach(sessions) { session in
                Button { selectedSession = session } label: {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(store.trainingCalendar.historyDayLabel(for: session.startedAt)).font(.caption).foregroundStyle(Color.gymLime)
                        Text(session.title).font(.headline).foregroundStyle(.white)
                        Text("\(session.completedSets) подх. · \(workoutTimeText(session.duration)) · \(weightText(session.volume)) кг")
                            .font(.subheadline).foregroundStyle(Color.gymMuted)
                    }.frame(maxWidth: .infinity, alignment: .leading).modifier(GymCard())
                }.buttonStyle(.plain)
            }
        }
    }
}

struct HistoryDetail: View {
    var session: WorkoutSession
    var calendar: TrainingCalendar
    var highlightedSetID: UUID? = nil
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                List {
                    Section {
                        LabeledContent("Дата", value: calendar.historyDayLabel(for: session.startedAt))
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
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text("Подход \(index + 1)").foregroundStyle(.secondary)
                                        if highlightedSetID == set.id { Text("Выбранный подход").font(.caption).foregroundStyle(Color.gymLime) }
                                    }
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
                                }.font(.subheadline).id(set.id)
                                    .listRowBackground(highlightedSetID == set.id ? Color.gymLime.opacity(0.1) : nil)
                            }
                            if !item.exercise.cue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("Сохранённая подсказка").font(.caption).foregroundStyle(.secondary)
                                    Text(item.exercise.cue).font(.subheadline)
                                }.padding(.vertical, 4)
                            }
                        }
                    }
                }
                .onAppear {
                    if let highlightedSetID { proxy.scrollTo(highlightedSetID, anchor: .center) }
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
