import SwiftUI
import Charts
import PhotosUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif

struct BodyProgressView: View {
    var store: BodyProgressStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var showPhotos = false
    @State private var selectedDate = Date()
    @State private var metric: BodyMetric = .weight
    @State private var selectedChartDate: Date?
    @State private var editing: BodyMeasurementEntry?
    @State private var addingPhoto = false
    @State private var selectedPhoto: BodyProgressPhoto?
    @State private var comparing = false
    @State private var removing: BodyMeasurementEntry?
    private var calendar: TrainingCalendar { TrainingCalendar() }
    private var dateKey: String { calendar.dayKey(for: selectedDate) }
    private var photos: [BodyProgressPhoto] { store.archive.photos.sorted { $0.date > $1.date } }

    var body: some View {
        NavigationStack {
            Group {
                if store.isRetired {
                    ContentUnavailableView("Аккаунт меняется", systemImage: "lock",
                        description: Text("Личные записи закрыты. Дождись открытия рабочего каталога."))
                } else if store.loadFailed {
                    ContentUnavailableView("Архив недоступен", systemImage: "lock.doc",
                        description: Text(store.errorMessage ?? BodyProgressError.invalidArchive.localizedDescription))
                } else {
                    content
                }
            }
            .background(Color.gymBackground)
            .navigationTitle("Замеры и фото")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Готово") { dismiss() } } }
            .sheet(item: $editing) { entry in
                BodyMeasurementEditor(store: store, entry: entry, original: store.entry(on: entry.date))
            }
            .sheet(isPresented: $addingPhoto) { BodyPhotoEditor(store: store, date: dateKey, timezone: calendar.calendar.timeZone.identifier) }
            .sheet(item: $selectedPhoto) { BodyPhotoDetail(store: store, photo: $0) }
            .sheet(isPresented: $comparing) { BodyPhotoComparison(store: store) }
            .confirmationDialog("Удалить замеры за \(removing?.date ?? "эту дату")?",
                isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                titleVisibility: .visible, presenting: removing) { entry in
                Button("Удалить замеры", role: .destructive) { store.removeEntry(entry); removing = nil }
                Button("Отмена", role: .cancel) { removing = nil }
            } message: { _ in Text("Фотографии и записи за другие даты сохранятся. Прежние резервные копии не меняются.") }
            .alert("Не удалось выполнить действие", isPresented: Binding(get: { store.errorMessage != nil && !store.loadFailed },
                set: { if !$0 { store.errorMessage = nil } })) {
                Button("Понятно") { store.errorMessage = nil }
            } message: { Text(store.errorMessage ?? "") }
            .overlay { if scenePhase != .active { Color.gymBackground.ignoresSafeArea().overlay { Image(systemName: "lock.fill").font(.largeTitle).foregroundStyle(Color.gymMuted) } } }
        }.tint(.gymLime).preferredColorScheme(.dark)
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Только на этом iPhone", systemImage: "lock").font(.subheadline.weight(.semibold))
                    Text("На сервер «Подхода» эти записи не отправляются. Восстановление зависит от резервной копии устройства в настройках iOS.")
                        .font(.caption).foregroundStyle(Color.gymMuted).fixedSize(horizontal: false, vertical: true)
                }.padding(.top, 16)
                Picker("Раздел личного прогресса", selection: $showPhotos) {
                    Text("Замеры").tag(false)
                    Text("Фото").tag(true)
                }.pickerStyle(.segmented)
                DatePicker("Дата записи", selection: $selectedDate, displayedComponents: .date)
                    .datePickerStyle(.compact)
                if showPhotos {
                    photoGallery
                } else {
                    Button {
                        editing = store.entry(on: dateKey) ?? BodyMeasurementEntry(date: dateKey,
                            timezone: calendar.calendar.timeZone.identifier, measurements: [])
                    } label: {
                        Label(store.entry(on: dateKey) == nil ? "Добавить замеры" : "Изменить замеры за дату", systemImage: "plus")
                    }.buttonStyle(PrimaryButton()).accessibilityIdentifier("body.measure.add")
                    measurementChart
                    measurementHistory
                }
            }.padding(.horizontal, 22).padding(.bottom, 24)
        }
    }

    private var measurementChart: some View {
        let points = store.archive.points(for: metric)
        let nearest = selectedChartDate.flatMap { selected in points.min {
            abs((calendar.date(from: $0.entry.date) ?? .distantPast).timeIntervalSince(selected)) <
                abs((calendar.date(from: $1.entry.date) ?? .distantPast).timeIntervalSince(selected))
        } } ?? points.last
        let minimum = points.map(\.value).min() ?? 0
        let maximum = points.map(\.value).max() ?? 1
        let margin = max(0.1, (maximum - minimum) * 0.1)
        return VStack(alignment: .leading, spacing: 15) {
            Picker("Показатель", selection: $metric) {
                ForEach(BodyMetric.allCases) { Text("\($0.title), \($0.unit)").tag($0) }
            }.pickerStyle(.menu).accessibilityIdentifier("body.chart.metric")
            if points.isEmpty {
                Text("Для этого показателя ещё нет замеров. Пустые поля не считаются нулём.")
                    .font(.subheadline).foregroundStyle(Color.gymMuted).padding(.vertical, 20)
            } else {
                Chart {
                    ForEach(points, id: \.entry.id) { point in
                        if let date = calendar.date(from: point.entry.date) {
                            LineMark(x: .value("Дата", date), y: .value(metric.unit, point.value)).foregroundStyle(Color.gymLime)
                            PointMark(x: .value("Дата", date), y: .value(metric.unit, point.value)).foregroundStyle(Color.gymLime)
                        }
                    }
                }
                .chartYScale(domain: max(0, minimum - margin)...(maximum + margin))
                .chartXAxis { AxisMarks(values: .automatic(desiredCount: 3)) { value in AxisGridLine(); AxisValueLabel(format: .dateTime.day().month(.abbreviated)) } }
                .chartXSelection(value: $selectedChartDate)
                .frame(height: 190)
                .accessibilityLabel("График: \(metric.title), \(metric.unit). Только измеренные значения.")
                if let nearest {
                    Text("\(nearest.entry.date) · \(nearest.value.formatted(.number.precision(.significantDigits(1...5)).locale(Locale(identifier: "ru_RU")))) \(metric.unit)")
                        .font(.headline.monospacedDigit())
                }
                Menu("Выбрать дату графика") {
                    ForEach(points, id: \.entry.id) { point in
                        Button(point.entry.date) { selectedChartDate = calendar.date(from: point.entry.date) }
                    }
                }.font(.subheadline).frame(minHeight: 44)
            }
        }.modifier(GymCard()).onChange(of: metric) { _, _ in selectedChartDate = nil }
    }

    private var measurementHistory: some View {
        LazyVStack(alignment: .leading, spacing: 16) {
            Text("Записи по датам").font(.title3.bold())
            if store.archive.entries.isEmpty {
                Text("Можно заполнить только нужные показатели. Каждый день сохраняется отдельно.")
                    .foregroundStyle(Color.gymMuted)
            }
            ForEach(store.archive.entries.sorted { $0.date > $1.date }) { entry in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Button { editing = entry } label: { Text(entry.date).font(.headline).frame(minHeight: 44) }
                        Spacer()
                        Button { removing = entry } label: { Image(systemName: "trash").frame(width: 44, height: 44) }
                            .foregroundStyle(.red).accessibilityLabel("Удалить замеры за \(entry.date)")
                    }
                    ForEach(entry.measurements, id: \.metric) { measurement in
                        LabeledContent("\(measurement.metric.title), \(measurement.metric.unit)",
                            value: measurement.value.formatted(.number.precision(.significantDigits(1...5)).locale(Locale(identifier: "ru_RU"))))
                            .font(.subheadline)
                    }
                }.modifier(GymCard())
            }
        }
    }

    private var photoGallery: some View {
        VStack(alignment: .leading, spacing: 18) {
            Button { addingPhoto = true } label: { Label("Добавить фото за дату", systemImage: "photo.badge.plus") }
                .buttonStyle(PrimaryButton())
            Button { comparing = true } label: { Label("Сравнить два фото", systemImage: "rectangle.split.2x1").frame(minHeight: 44) }
                .buttonStyle(.bordered).disabled(photos.count < 2)
            if store.hasPendingDeletions {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Не все скрытые фото удалены с диска.").font(.subheadline)
                    Button("Повторить удаление файлов") { store.retryPendingPhotoDeletions() }.frame(minHeight: 44)
                }
            }
            if photos.isEmpty {
                ContentUnavailableView("Личный фотоархив", systemImage: "photo",
                    description: Text("Выбирай свои снимки и ракурс. Приложение хранит отдельную копию без исходных координат и сведений камеры."))
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 145), spacing: 14)], spacing: 18) {
                ForEach(photos) { photo in
                    Button { selectedPhoto = photo } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            BodyPhotoImage(store: store, photoID: photo.id, maximumDimension: 400)
                                .frame(height: 190).frame(maxWidth: .infinity)
                                .background(Color.gymCard, in: RoundedRectangle(cornerRadius: 12))
                            Text(photo.date).font(.subheadline.bold()).foregroundStyle(.primary)
                            Text(photo.angle.title).font(.caption).foregroundStyle(Color.gymMuted)
                        }
                    }.buttonStyle(.plain).accessibilityLabel("Фото \(photo.date), \(photo.angle.title)")
                }
            }
        }
    }
}

private struct BodyMeasurementEditor: View {
    var store: BodyProgressStore
    let entry: BodyMeasurementEntry
    let original: BodyMeasurementEntry?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var fields: [BodyMetric: String]
    @State private var error: String?
    @FocusState private var focused: BodyMetric?

    init(store: BodyProgressStore, entry: BodyMeasurementEntry, original: BodyMeasurementEntry?) {
        self.store = store; self.entry = entry; self.original = original
        _fields = State(initialValue: Dictionary(uniqueKeysWithValues: entry.measurements.map { ($0.metric, String($0.value).replacingOccurrences(of: ".", with: ",")) }))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Дата", value: entry.date)
                    ForEach(BodyMetric.allCases) { metric in
                        LabeledContent("\(metric.title), \(metric.unit)") {
                            TextField("Не измерено", text: Binding(get: { fields[metric] ?? "" }, set: { fields[metric] = $0 }))
                                .multilineTextAlignment(.trailing).frame(minWidth: 80, maxWidth: 140)
                                .focused($focused, equals: metric)
                                #if os(iOS)
                                .keyboardType(.decimalPad)
                                #endif
                                .accessibilityIdentifier("body.metric.\(metric.rawValue)")
                        }
                    }
                } footer: { Text("Заполни хотя бы одно поле. Пустое останется неизвестным, а не нулём.") }
            }
            .navigationTitle(original == nil ? "Новые замеры" : "Изменить замеры")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Сохранить") {
                        var changed = entry
                        var values: [BodyMeasurement] = []
                        for metric in BodyMetric.allCases {
                            let text = (fields[metric] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                            if text.isEmpty { continue }
                            guard let number = Double(text.replacingOccurrences(of: ",", with: ".")),
                                  BodyMeasurement(metric: metric, value: number).isValid else {
                                error = "\(metric.title): укажи положительное число до \(Int(metric.maximum)) \(metric.unit)."
                                return
                            }
                            values.append(BodyMeasurement(metric: metric, value: number))
                        }
                        changed.measurements = values
                        if store.saveEntry(changed, expected: original) { dismiss() }
                        else { error = store.errorMessage; store.errorMessage = nil }
                    }.disabled(store.isRetired)
                }
                #if os(iOS)
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Готово") { focused = nil }.accessibilityIdentifier("body.keyboard.done")
                }
                #endif
            }
            .alert("Проверь замеры", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("Понятно") { error = nil }
            } message: { Text(error ?? "") }
            .overlay { if scenePhase != .active || store.isRetired { Color.gymBackground.ignoresSafeArea() } }
        }.tint(.gymLime).preferredColorScheme(.dark)
    }
}

private struct BodyPhotoEditor: View {
    var store: BodyProgressStore
    let date: String
    let timezone: String
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var angle: ProgressPhotoAngle = .front
    @State private var selection: PhotosPickerItem?
    @State private var prepared: Data?
    @State private var importing = false
    @State private var error: String?
    @State private var photoID = UUID()

    var body: some View {
        let pickerTitle = prepared == nil ? "Выбрать фото" : "Выбрать другое фото"
        return NavigationStack {
            Form {
                Section {
                    LabeledContent("Дата", value: date)
                    Picker("Ракурс", selection: $angle) { ForEach(ProgressPhotoAngle.allCases) { Text($0.title).tag($0) } }
                        .pickerStyle(.menu).accessibilityIdentifier("body.photo.angle")
                    PhotosPicker(selection: $selection, matching: .images) {
                        Label(pickerTitle, systemImage: "photo")
                    }.disabled(importing || store.isRetired)
                    if importing { SwiftUI.ProgressView("Подготовка приватной копии…") }
                    if let prepared { BodyPreparedImage(data: prepared).frame(maxWidth: .infinity).frame(height: 300) }
                } footer: {
                    Text("Сохраняется отдельная копия до 2048 px без исходных координат и данных камеры. Оригинал в медиатеке не меняется. Только на этом iPhone; старые резервные копии управляются отдельно.")
                }
            }
            .navigationTitle("Новое фото")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Сохранить фото") {
                        guard let prepared else { return }
                        let photo = BodyProgressPhoto(id: photoID, date: date, timezone: timezone, angle: angle)
                        if store.addPhoto(photo, preparedJPEG: prepared) { dismiss() }
                        else { error = store.errorMessage; store.errorMessage = nil }
                    }.disabled(prepared == nil || importing || store.isRetired)
                }
            }
            .task(id: selection) {
                guard let selection else { prepared = nil; return }
                importing = true
                prepared = nil
                defer { importing = false }
                do {
                    guard let data = try await selection.loadTransferable(type: Data.self) else { throw BodyProgressError.invalidPhoto }
                    try Task.checkCancellation()
                    let image = try await ProgressPhotoPreparation.shared.prepare(data)
                    try Task.checkCancellation()
                    guard !store.isRetired, scenePhase == .active else { return }
                    prepared = image
                } catch is CancellationError {} catch { self.error = error.localizedDescription }
            }
            .onChange(of: scenePhase) { _, phase in if phase != .active { selection = nil; prepared = nil } }
            .alert("Не удалось добавить фото", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("Понятно") { error = nil }
            } message: { Text(error ?? "") }
            .overlay { if scenePhase != .active || store.isRetired { Color.gymBackground.ignoresSafeArea() } }
        }.tint(.gymLime).preferredColorScheme(.dark)
    }
}

private struct BodyPhotoImage: View {
    var store: BodyProgressStore
    let photoID: UUID
    let maximumDimension: Int
    @Environment(\.scenePhase) private var scenePhase
    @State private var image: Data?
    @State private var unavailable = false

    var body: some View {
        Group {
            if let image { BodyPreparedImage(data: image) }
            else if unavailable {
                VStack(spacing: 8) { Image(systemName: "photo.badge.exclamationmark"); Text("Копия недоступна").font(.caption) }
                    .foregroundStyle(Color.gymMuted)
            } else { SwiftUI.ProgressView().tint(.gymLime) }
        }
        .task(id: scenePhase) {
            guard scenePhase == .active, !store.isRetired else { image = nil; return }
            do {
                let source = try store.photoData(for: photoID)
                let preview = try await ProgressPhotoPreparation.shared.preview(source, maximumDimension: maximumDimension)
                try Task.checkCancellation()
                guard !store.isRetired else { return }
                image = preview
                unavailable = false
            } catch is CancellationError {} catch { unavailable = true; image = nil }
        }
        .onDisappear { image = nil }
        .onChange(of: scenePhase) { _, phase in if phase != .active { image = nil } }
        .onChange(of: store.isRetired) { _, retired in if retired { image = nil } }
    }
}

private struct BodyPreparedImage: View {
    let data: Data
    var body: some View {
        #if os(iOS)
        if let image = UIImage(data: data) { Image(uiImage: image).resizable().scaledToFit().accessibilityLabel("Личное фото прогресса") }
        #else
        if let image = NSImage(data: data) { Image(nsImage: image).resizable().scaledToFit().accessibilityLabel("Личное фото прогресса") }
        #endif
    }
}

private struct BodyPhotoDetail: View {
    var store: BodyProgressStore
    let photo: BodyProgressPhoto
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var confirmRemoval = false

    var body: some View {
        NavigationStack {
            Form {
                BodyPhotoImage(store: store, photoID: photo.id, maximumDimension: 2048).frame(height: 400).frame(maxWidth: .infinity)
                LabeledContent("Дата", value: photo.date)
                LabeledContent("Ракурс", value: photo.angle.title)
                Section {
                    Button("Удалить копию фото", role: .destructive) { confirmRemoval = true }
                } footer: { Text("Удаляется копия текущего аккаунта. Оригинал в медиатеке и прежние резервные копии не меняются.") }
            }
            .navigationTitle("Личное фото")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Готово") { dismiss() } } }
            .confirmationDialog("Удалить копию фото?", isPresented: $confirmRemoval, titleVisibility: .visible) {
                Button("Удалить фото", role: .destructive) {
                    _ = store.removePhoto(photo)
                    if !store.archive.photos.contains(where: { $0.id == photo.id }) { dismiss() }
                }
                Button("Отмена", role: .cancel) {}
            } message: { Text("Оригинал и прежние резервные копии останутся. Это действие относится только к копии в текущем рабочем каталоге.") }
            .overlay { if scenePhase != .active || store.isRetired { Color.gymBackground.ignoresSafeArea() } }
        }.tint(.gymLime).preferredColorScheme(.dark)
    }
}

private struct BodyPhotoComparison: View {
    var store: BodyProgressStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var first: UUID?
    @State private var second: UUID?
    private var photos: [BodyProgressPhoto] { store.archive.photos.sorted { $0.date < $1.date } }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Picker("Первое фото", selection: $first) {
                        Text("Выбрать").tag(UUID?.none)
                        ForEach(Array(photos.enumerated()), id: \.element.id) { index, photo in
                            Text("\(photo.date) · \(photo.angle.title) · снимок \(index + 1)").tag(Optional(photo.id))
                        }
                    }.pickerStyle(.menu).accessibilityIdentifier("body.compare.first")
                    Picker("Второе фото", selection: $second) {
                        Text("Выбрать").tag(UUID?.none)
                        ForEach(Array(photos.enumerated()), id: \.element.id) { index, photo in
                            Text("\(photo.date) · \(photo.angle.title) · снимок \(index + 1)").tag(Optional(photo.id))
                        }
                    }.pickerStyle(.menu).accessibilityIdentifier("body.compare.second")
                    if let first, let second, first != second {
                        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: 20)) : AnyLayout(HStackLayout(alignment: .top, spacing: 12))
                        layout {
                            ForEach([first, second], id: \.self) { id in
                                if let photo = photos.first(where: { $0.id == id }) {
                                    VStack(alignment: .leading, spacing: 8) {
                                        BodyPhotoImage(store: store, photoID: id, maximumDimension: 2048).frame(height: 330).frame(maxWidth: .infinity)
                                        Text(photo.date).font(.headline)
                                        Text(photo.angle.title).font(.caption).foregroundStyle(Color.gymMuted)
                                    }.frame(maxWidth: .infinity)
                                }
                            }
                        }.accessibilityElement(children: .contain).accessibilityIdentifier("body.photo.comparison")
                    } else {
                        ContentUnavailableView("Выбери два разных снимка", systemImage: "rectangle.split.2x1",
                            description: Text("Для сравнения удобнее одинаковый ракурс и похожее освещение. Фото не меняются и не анализируются приложением."))
                    }
                }.padding(22)
            }.background(Color.gymBackground)
            .navigationTitle("Сравнение фото")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Готово") { dismiss() } } }
            .overlay { if scenePhase != .active || store.isRetired { Color.gymBackground.ignoresSafeArea() } }
        }.tint(.gymLime).preferredColorScheme(.dark)
    }
}
