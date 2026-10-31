import SwiftUI
import UniformTypeIdentifiers

private struct NutritionExportFile: FileDocument {
    static let readableContentTypes: [UTType] = [.json]
    var data: Data

    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        self.data = data
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

struct NutritionExportView: View {
    var sync: NutritionSynchronization
    @Environment(\.dismiss) private var dismiss
    @State private var start = Date()
    @State private var end = Date()
    @State private var preparing = false
    @State private var exportTask: Task<Void, Never>?
    @State private var file: NutritionExportFile?
    @State private var showExporter = false
    @State private var errorMessage: String?

    var body: some View {
        Form {
            Section("Выбранные даты") {
                DatePicker("С", selection: $start, displayedComponents: .date)
                DatePicker("По", selection: $end, displayedComponents: .date)
                Text("От 1 до 366 дней за один экспорт. В JSON сохраняются порции, состав и снимки целей каждого дня.").font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Text("Для аккаунта загружаются актуальные дни с сервера; неотправленные записи и конфликты нужно разрешить заранее. В гостевом режиме экспортируются локальные записи.")
                    .font(.subheadline)
                Text("Файл содержит личные записи питания. Выбери место сохранения сам.").font(.caption).foregroundStyle(.secondary)
                Button {
                    preparing = true
                    errorMessage = nil
                    exportTask = Task {
                        defer { preparing = false }
                        do {
                            let calendar = TrainingCalendar()
                            let range = try NutritionExportRange(from: calendar.dayKey(for: start), through: calendar.dayKey(for: end),
                                timezone: calendar.calendar.timeZone.identifier)
                            let export = try await sync.exportDays(range)
                            try Task.checkCancellation()
                            let encoder = JSONEncoder()
                            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                            file = NutritionExportFile(data: try encoder.encode(export))
                            showExporter = true
                        } catch is CancellationError {
                            return
                        } catch { errorMessage = error.localizedDescription }
                    }
                } label: {
                    if preparing { ProgressView("Подготовка…") }
                    else { Label("Сохранить JSON", systemImage: "square.and.arrow.down") }
                }.disabled(preparing || sync.isSyncing)
                if let errorMessage { Text(errorMessage).font(.caption).foregroundStyle(Color.orange) }
            }
        }.navigationTitle("Экспорт питания")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Закрыть") { exportTask?.cancel(); dismiss() } } }
            .fileExporter(isPresented: $showExporter, document: file, contentType: .json, defaultFilename: "podhod-nutrition") { result in
                if case .failure(let error) = result { errorMessage = error.localizedDescription }
                file = nil
            }
            .onDisappear { exportTask?.cancel() }
    }
}
