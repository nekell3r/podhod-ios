import SwiftUI

private enum KnowledgePage: String, CaseIterable, Identifiable {
    case articles = "Основы", technique = "Техника", saved = "Сохранённое"
    var id: String { rawValue }
}

struct KnowledgeView: View {
    var bookmarks: KnowledgeBookmarks
    @Environment(\.dismiss) private var dismiss
    @State private var page: KnowledgePage = .articles
    @State private var query = ""
    @State private var selectedExercise: ExerciseCatalogEntry?
    private let catalog = KnowledgeCatalog.bundled
    private let exercises = ExerciseCatalog.bundled

    private var articles: [KnowledgeArticle] {
        catalog.search(query: query).filter { page != .saved || bookmarks.articleIDs.contains($0.id) }
    }
    private var technique: [ExerciseCatalogEntry] {
        exercises.search(query: query).filter { page != .saved || bookmarks.exerciseIDs.contains($0.id) }
    }
    private var unavailableCount: Int {
        bookmarks.articleIDs.subtracting(Set(catalog.articles.map(\.id))).count +
            bookmarks.exerciseIDs.subtracting(Set(exercises.exercises.map(\.id))).count
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Раздел базы знаний", selection: $page) {
                    ForEach(KnowledgePage.allCases) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).padding(.horizontal, 20).padding(.vertical, 12)
                if page == .saved && bookmarks.isRetired {
                    ContentUnavailableView("Сохранённое закрыто", systemImage: "lock",
                        description: Text("Дождись открытия рабочего каталога аккаунта."))
                } else if page == .saved && bookmarks.loadFailed {
                    ContentUnavailableView("Сохранённое недоступно", systemImage: "bookmark.slash",
                        description: Text(bookmarks.errorMessage ?? KnowledgeError.invalidBookmarks.localizedDescription))
                } else {
                    List {
                        if page != .technique && !articles.isEmpty {
                            Section("Материалы") {
                                ForEach(articles) { article in
                                    NavigationLink {
                                        KnowledgeArticleView(article: article, bookmarks: bookmarks)
                                    } label: {
                                        HStack(alignment: .top, spacing: 12) {
                                            VStack(alignment: .leading, spacing: 6) {
                                                Text(article.title).font(.headline)
                                                Text(article.summary).font(.subheadline).foregroundStyle(Color.gymMuted).lineLimit(3)
                                            }
                                            if bookmarks.articleIDs.contains(article.id) {
                                                Image(systemName: "bookmark.fill").foregroundStyle(Color.gymLime).accessibilityLabel("Сохранено")
                                            }
                                        }.padding(.vertical, 5)
                                    }.accessibilityIdentifier("knowledge.article.\(article.id)")
                                }
                            }.listRowBackground(Color.gymCard)
                        }
                        if page != .articles && !technique.isEmpty {
                            Section("Техника упражнений") {
                                ForEach(technique) { entry in
                                    Button { selectedExercise = entry } label: {
                                        HStack(alignment: .top, spacing: 12) {
                                            VStack(alignment: .leading, spacing: 6) {
                                                Text(entry.exercise.name).font(.headline).foregroundStyle(.white)
                                                Text(entry.exercise.muscle).font(.subheadline).foregroundStyle(Color.gymMuted)
                                            }
                                            Spacer(minLength: 0)
                                            if bookmarks.exerciseIDs.contains(entry.id) {
                                                Image(systemName: "bookmark.fill").foregroundStyle(Color.gymLime).accessibilityLabel("Сохранено")
                                            }
                                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(Color.gymMuted)
                                        }.padding(.vertical, 5)
                                    }.accessibilityIdentifier("knowledge.exercise.\(entry.id.uuidString)")
                                }
                            }.listRowBackground(Color.gymCard)
                        }
                        if (page == .articles && articles.isEmpty) || (page == .technique && technique.isEmpty) ||
                            (page == .saved && articles.isEmpty && technique.isEmpty) {
                            Section {
                                if query.isEmpty && page == .saved {
                                    ContentUnavailableView("Сохраняй полезное", systemImage: "bookmark",
                                        description: Text("Нажми закладку в материале или карточке техники. Сохранённое остаётся на этом iPhone в текущем аккаунте."))
                                } else {
                                    ContentUnavailableView("Ничего не найдено", systemImage: "magnifyingglass",
                                        description: Text("Измени запрос или выбери другой раздел."))
                                }
                            }.listRowBackground(Color.clear)
                        }
                        Section {
                            Text(page == .saved ? "Закладки хранятся локально, отдельно для гостя и каждого аккаунта." :
                                "Материалы «Подхода» и карточки каталога. Источники и лицензии указаны внутри. Видео остаются на сайте автора, если это предусмотрено источником.")
                                .font(.caption).foregroundStyle(Color.gymMuted)
                            if page == .saved && unavailableCount > 0 {
                                Text("Недоступно в этой версии: \(unavailableCount). Закладки сохранены и не удаляются автоматически.")
                                    .font(.caption).foregroundStyle(Color.gymMuted)
                            }
                        }.listRowBackground(Color.clear)
                    }
                    .scrollContentBackground(.hidden).listStyle(.insetGrouped)
                }
            }
            .background(Color.gymBackground)
            .navigationTitle("База знаний")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Материал, упражнение, мышца")
            #else
            .searchable(text: $query, prompt: "Материал, упражнение, мышца")
            #endif
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Готово") { dismiss() } } }
            .sheet(item: $selectedExercise) { ExerciseDetailView(exercise: $0.exercise, bookmarks: bookmarks) }
            .alert("Не удалось изменить сохранённое", isPresented: Binding(get: { bookmarks.errorMessage != nil && !bookmarks.loadFailed },
                set: { if !$0 { bookmarks.errorMessage = nil } })) {
                Button("Понятно") { bookmarks.errorMessage = nil }
            } message: { Text(bookmarks.errorMessage ?? "") }
        }.tint(.gymLime).preferredColorScheme(.dark)
    }
}

private struct KnowledgeArticleView: View {
    let article: KnowledgeArticle
    var bookmarks: KnowledgeBookmarks

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(article.title).font(.title.bold())
                    Text(article.summary).font(.subheadline).foregroundStyle(Color.gymMuted).lineSpacing(4)
                }
                ForEach(article.sections) { section in
                    VStack(alignment: .leading, spacing: 12) {
                        Text(section.title).font(.title3.bold())
                        ForEach(Array(section.paragraphs.enumerated()), id: \.offset) { _, paragraph in
                            Text(paragraph).font(.body).lineSpacing(5)
                        }
                    }
                }
                if !article.mistakes.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Частые ошибки").font(.title3.bold())
                        ForEach(Array(article.mistakes.enumerated()), id: \.offset) { _, mistake in
                            Text(mistake).font(.body).lineSpacing(5)
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 12) {
                    Text("Источники").font(.title3.bold())
                    Text("Текст: «Подход», по материалам ниже.").font(.caption).foregroundStyle(Color.gymMuted)
                    ForEach(article.sources) { source in
                        if let url = URL(string: source.url) {
                            Link(destination: url) {
                                VStack(alignment: .leading, spacing: 6) {
                                    Label(source.title, systemImage: "arrow.up.right.square").font(.subheadline)
                                    Text(source.author).font(.caption).foregroundStyle(Color.gymMuted)
                                }.fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 6)
                            }
                        }
                    }
                }
            }.padding(22).textSelection(.enabled)
        }
        .background(Color.gymBackground)
        .navigationTitle("Материал")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                let saved = bookmarks.articleIDs.contains(article.id)
                Button {
                    bookmarks.setArticle(article.id, saved: !saved)
                } label: { Image(systemName: saved ? "bookmark.fill" : "bookmark") }
                    .accessibilityLabel(saved ? "Убрать материал из сохранённого" : "Сохранить материал")
                    .accessibilityIdentifier("knowledge.article.save")
                    .disabled(bookmarks.loadFailed || bookmarks.isRetired)
            }
        }
    }
}
