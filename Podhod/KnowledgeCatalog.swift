import Foundation

struct KnowledgeSource: Codable, Equatable, Identifiable {
    let title: String
    let author: String
    let url: String
    var id: String { url }
}

struct KnowledgeSection: Codable, Equatable, Identifiable {
    let title: String
    let paragraphs: [String]
    var id: String { title }
}

struct KnowledgeArticle: Codable, Equatable, Identifiable {
    let id: String
    let title: String
    let summary: String
    let tags: [String]
    let sections: [KnowledgeSection]
    let mistakes: [String]
    let sources: [KnowledgeSource]

    var isValid: Bool {
        id.range(of: "^[a-z0-9-]{1,80}$", options: .regularExpression) != nil &&
            !title.isEmpty && title.count <= 200 && !summary.isEmpty && summary.count <= 1000 &&
            tags.count <= 20 && Set(tags).count == tags.count && tags.allSatisfy({ !$0.isEmpty && $0.count <= 100 }) &&
            (1...16).contains(sections.count) && Set(sections.map(\.title)).count == sections.count &&
            sections.allSatisfy({ !$0.title.isEmpty && $0.title.count <= 200 && (1...20).contains($0.paragraphs.count) &&
                $0.paragraphs.allSatisfy({ !$0.isEmpty && $0.count <= 20_000 }) }) &&
            mistakes.count <= 20 && mistakes.allSatisfy({ !$0.isEmpty && $0.count <= 2000 }) &&
            (1...10).contains(sources.count) && Set(sources.map(\.url)).count == sources.count && sources.allSatisfy {
                guard !$0.title.isEmpty, $0.title.count <= 500, !$0.author.isEmpty, $0.author.count <= 500,
                      $0.url.count <= 2048, let url = URL(string: $0.url) else { return false }
                return url.scheme == "https" && url.host?.isEmpty == false && url.user == nil && url.password == nil
            }
    }

    func matches(query: String) -> Bool {
        let locale = Locale(identifier: "ru_RU")
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: locale)
        if query.isEmpty { return true }
        let terms = [title, summary] + tags + mistakes + sections.flatMap { [$0.title] + $0.paragraphs }
        return terms.contains { $0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: locale).contains(query) }
    }
}

struct KnowledgeCatalog: Decodable, Equatable {
    let version: Int
    let articles: [KnowledgeArticle]

    init(data: Data) throws {
        self = try JSONDecoder().decode(Self.self, from: data)
    }

    private enum CodingKeys: String, CodingKey { case version, articles }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decode(Int.self, forKey: .version)
        articles = try values.decode([KnowledgeArticle].self, forKey: .articles)
        guard version == 1, (1...200).contains(articles.count), Set(articles.map(\.id)).count == articles.count,
              articles.allSatisfy(\.isValid) else { throw KnowledgeError.invalidCatalog }
    }

    static let bundled: KnowledgeCatalog = {
        #if SWIFT_PACKAGE
        let bundle = Bundle.module
        #else
        let bundle = Bundle.main
        #endif
        guard let url = bundle.url(forResource: "knowledge-catalog", withExtension: "json"),
              let data = try? Data(contentsOf: url), let catalog = try? KnowledgeCatalog(data: data) else {
            fatalError("Invalid bundled knowledge-catalog.json. Check the target resources.")
        }
        return catalog
    }()

    func search(query: String) -> [KnowledgeArticle] { articles.filter { $0.matches(query: query) } }
}

enum KnowledgeError: LocalizedError {
    case invalidCatalog, invalidBookmarks, unsupportedBookmarks, accountMismatch, saveFailed, capacity
    var errorDescription: String? {
        switch self {
        case .invalidCatalog: "Материалы этой версии недоступны. Обнови приложение."
        case .invalidBookmarks: "Не удалось открыть сохранённое. Исходный файл защищён от перезаписи."
        case .unsupportedBookmarks: "Сохранённое создано другой версией приложения. Файл не изменён."
        case .accountMismatch: "Эти сохранённые материалы относятся к другому аккаунту."
        case .saveFailed: "Не удалось изменить сохранённое. Прежние записи сохранены; повтори действие."
        case .capacity: "Достигнут предел 500 сохранённых материалов. Удали часть из «Сохранённого» перед добавлением."
        }
    }
}
