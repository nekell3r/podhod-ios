import SwiftUI

struct SavedTrainingTemplatesView: View {
    var store: WorkoutStore
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var showSave = false
    @State private var applying: SavedTrainingTemplate?
    @State private var expectedDays: [TrainingDay] = []
    @State private var removing: SavedTrainingTemplate?
    @State private var updating: SavedTrainingTemplate?

    var body: some View {
        NavigationStack {
            templateList
            .navigationTitle("Сохранённые шаблоны")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Готово") { dismiss() } } }
            .alert("Сохранить шаблон", isPresented: $showSave) {
                TextField("Название", text: $name)
                Button("Сохранить") { store.saveTemplateSnapshot(name: name) }
                Button("Отмена", role: .cancel) {}
            } message: { Text("Сохранятся все семь дней текущего шаблона недели.") }
            .confirmationDialog("Применить шаблон?", isPresented: Binding(get: { applying != nil }, set: { if !$0 { applying = nil } }),
                                titleVisibility: .visible, presenting: applying) { snapshot in
                Button("Применить «\(snapshot.name)»") {
                    store.applyTemplateSnapshot(snapshot, expected: expectedDays)
                    applying = nil
                }
                Button("Отмена", role: .cancel) { applying = nil }
            } message: { _ in Text("Текущий шаблон будет заменён. Если он нужен, сначала сохрани его отдельным вариантом. Применённый шаблон можно редактировать в разделе «Шаблон недели».") }
            .confirmationDialog("Обновить сохранённый шаблон?", isPresented: Binding(get: { updating != nil }, set: { if !$0 { updating = nil } }),
                                titleVisibility: .visible, presenting: updating) { snapshot in
                Button("Обновить «\(snapshot.name)»") {
                    store.saveTemplateSnapshot(name: snapshot.name, replacing: snapshot)
                    updating = nil
                }
                Button("Отмена", role: .cancel) { updating = nil }
            } message: { _ in Text("В сохранённый вариант запишутся все дни текущего шаблона недели.") }
            .confirmationDialog("Удалить сохранённый шаблон?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                                titleVisibility: .visible, presenting: removing) { snapshot in
                Button("Удалить «\(snapshot.name)»", role: .destructive) {
                    store.deleteTemplateSnapshot(snapshot)
                    removing = nil
                }
                Button("Отмена", role: .cancel) { removing = nil }
            } message: { _ in Text("Текущий шаблон, недели и тренировки останутся.") }
            .alert("Не удалось сохранить", isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) {
                Button("Понятно") { store.errorMessage = nil }
            } message: { Text(store.errorMessage ?? "") }
        }.tint(.gymLime).preferredColorScheme(.dark)
    }

    private var templateList: some View {
    List {
        Section {
            Button("Сохранить текущий шаблон", systemImage: "plus") {
                name = ""
                showSave = true
            }.disabled(store.savedTemplatesState.document.templates.count >= 20)
                .accessibilityIdentifier("templates.save")
        } footer: {
            Text("Сохрани до 20 вариантов недели с разными названиями. Применение заменяет текущий шаблон. Созданные недели, цикл, активная тренировка и история сохраняются.")
        }
        if store.savedTemplatesState.document.templates.isEmpty {
            ContentUnavailableView("Сохранённых шаблонов пока нет", systemImage: "square.stack",
                description: Text("Составь шаблон недели и сохрани его здесь. Затем можно создать и сохранить другой вариант."))
        }
        ForEach(store.savedTemplatesState.document.templates) { snapshot in
            snapshotSection(snapshot)
        }
    }
    }

    private func snapshotSection(_ snapshot: SavedTrainingTemplate) -> some View {
        Section {
            DisclosureGroup {
                ForEach(snapshot.days) { day in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(day.name).font(.subheadline.bold())
                        Text(day.exercises.isEmpty ? "Отдых" : day.title).font(.subheadline)
                        ForEach(day.exercises) { plan in
                            Text("\(plan.exercise.name) · \(plan.setCount) × \(plan.targetReps)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }.padding(.vertical, 4)
                }
            } label: {
                VStack(alignment: .leading, spacing: 5) {
                    Text(snapshot.name).font(.headline)
                    Text("Дней с тренировками: \(snapshot.days.filter { !$0.exercises.isEmpty }.count)")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Button("Применить шаблон", systemImage: "checkmark.circle") {
                expectedDays = store.archive.week
                applying = snapshot
            }.accessibilityIdentifier("templates.apply.\(snapshot.name)")
            Button("Обновить из текущего шаблона", systemImage: "arrow.triangle.2.circlepath") { updating = snapshot }
            Button("Удалить шаблон", systemImage: "trash", role: .destructive) { removing = snapshot }
        }
    }
}
