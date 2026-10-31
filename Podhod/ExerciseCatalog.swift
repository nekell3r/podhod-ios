import Foundation

struct ExerciseMuscle: Codable, Identifiable, Equatable {
    let id: String
    let name: String
}

struct ExerciseEquipment: Codable, Identifiable, Equatable {
    let id: String
    let name: String
}

struct ExerciseAttribution: Codable, Equatable {
    let author: String
    let license: String
    let licenseURL: String
    let sourceURL: String
}

enum ExerciseVideoPlayback: String, Codable {
    case external
}

struct ExerciseVideo: Codable, Identifiable, Equatable {
    let id: String
    let url: String
    let author: String
    let license: String
    let licenseURL: String
    let sourceURL: String
    let playback: ExerciseVideoPlayback?
}

struct ExerciseIDAlias: Codable, Identifiable, Equatable {
    let id: UUID
    let exerciseID: UUID
}

struct ExerciseCatalogEntry: Codable, Identifiable, Equatable {
    let exercise: Exercise
    let aliases: [String]
    let primaryMuscles: [String]
    let secondaryMuscles: [String]
    let equipment: [String]
    let instructions: [String]
    let videos: [ExerciseVideo]
    let sourceURL: String
    let attribution: ExerciseAttribution
    var id: UUID { exercise.id }
}

struct ExerciseCatalog: Decodable, Equatable {
    let version: String
    let muscles: [ExerciseMuscle]
    let equipment: [ExerciseEquipment]
    let exercises: [ExerciseCatalogEntry]
    let exerciseIDAliases: [ExerciseIDAlias]

    static let bundled: ExerciseCatalog = {
        #if SWIFT_PACKAGE
        let bundle = Bundle.module
        #else
        let bundle = Bundle.main
        #endif
        guard let url = bundle.url(forResource: "exercise-catalog", withExtension: "json") else {
            fatalError("Missing bundled exercise-catalog.json. Check the target's resource configuration.")
        }
        do {
            return try ExerciseCatalog(data: Data(contentsOf: url))
        } catch {
            fatalError("Invalid bundled exercise-catalog.json: \(error)")
        }
    }()

    init(data: Data) throws {
        self = try JSONDecoder().decode(Self.self, from: data)
    }

    private enum CodingKeys: String, CodingKey {
        case version, muscles, equipment, exercises, exerciseIDAliases
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decode(String.self, forKey: .version)
        muscles = try values.decode([ExerciseMuscle].self, forKey: .muscles)
        equipment = try values.decode([ExerciseEquipment].self, forKey: .equipment)
        exercises = try values.decode([ExerciseCatalogEntry].self, forKey: .exercises)
        exerciseIDAliases = try values.decodeIfPresent([ExerciseIDAlias].self, forKey: .exerciseIDAliases) ?? []
        try validate()
    }

    func entry(for exerciseID: UUID) -> ExerciseCatalogEntry? {
        let canonicalID = exerciseIDAliases.first { $0.id == exerciseID }?.exerciseID ?? exerciseID
        return exercises.first { $0.exercise.id == canonicalID }
    }

    func illustration(for exercise: Exercise) -> String {
        if !exercise.illustration.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return exercise.illustration
        }
        return entry(for: exercise.id)?.exercise.illustration ?? exercise.illustration
    }

    func search(query: String = "", muscleID: String? = nil, equipmentID: String? = nil) -> [ExerciseCatalogEntry] {
        let locale = Locale(identifier: "ru_RU")
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: locale)
        return exercises.filter { entry in
            if let muscleID, !entry.primaryMuscles.contains(muscleID) && !entry.secondaryMuscles.contains(muscleID) {
                return false
            }
            if let equipmentID, !entry.equipment.contains(equipmentID) { return false }
            if query.isEmpty { return true }
            let muscleNames = muscles.filter { entry.primaryMuscles.contains($0.id) || entry.secondaryMuscles.contains($0.id) }.map(\.name)
            let equipmentNames = equipment.filter { entry.equipment.contains($0.id) }.map(\.name)
            let terms = [entry.exercise.name, entry.exercise.muscle] + entry.aliases + muscleNames + equipmentNames
            return terms.contains { $0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: locale).contains(query) }
        }
    }

    func replacements(for exercise: Exercise, query: String = "", equipmentID: String? = nil) -> [ExerciseCatalogEntry] {
        guard let original = entry(for: exercise.id) else { return [] }
        let primary = Set(original.primaryMuscles)
        let equipment = Set(original.equipment)
        return search(query: query, equipmentID: equipmentID).filter {
            $0.id != original.id && !primary.isDisjoint(with: $0.primaryMuscles)
        }.sorted { left, right in
            let leftMuscles = primary.intersection(left.primaryMuscles).count
            let rightMuscles = primary.intersection(right.primaryMuscles).count
            if leftMuscles != rightMuscles { return leftMuscles > rightMuscles }
            let leftEquipment = equipment.intersection(left.equipment).count
            let rightEquipment = equipment.intersection(right.equipment).count
            if leftEquipment != rightEquipment { return leftEquipment > rightEquipment }
            return left.exercise.name.localizedStandardCompare(right.exercise.name) == .orderedAscending
        }
    }

    private func validate() throws {
        func invalid(_ message: String) -> DecodingError {
            .dataCorrupted(.init(codingPath: [], debugDescription: "Invalid exercise catalog: \(message)"))
        }
        guard !version.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !exercises.isEmpty else {
            throw invalid("version and exercises are required")
        }
        let muscleIDs = Set(muscles.map(\.id))
        let equipmentIDs = Set(equipment.map(\.id))
        let exerciseIDs = Set(exercises.map(\.id))
        guard muscleIDs.count == muscles.count,
              muscles.allSatisfy({ !$0.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
              equipmentIDs.count == equipment.count,
              equipment.allSatisfy({ !$0.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
              exerciseIDs.count == exercises.count else {
            throw invalid("identifiers must be unique and taxonomy entries must have names")
        }
        let aliasIDs = Set(exerciseIDAliases.map(\.id))
        guard aliasIDs.count == exerciseIDAliases.count, aliasIDs.isDisjoint(with: exerciseIDs),
              exerciseIDAliases.allSatisfy({ exerciseIDs.contains($0.exerciseID) }) else {
            throw invalid("exercise ID aliases must be unique, distinct from canonical IDs and reference canonical exercises directly")
        }
        for entry in exercises {
            guard !entry.exercise.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  Set(entry.primaryMuscles + entry.secondaryMuscles).isSubset(of: muscleIDs),
                  Set(entry.equipment).isSubset(of: equipmentIDs) else {
                throw invalid("exercise \(entry.id) has a missing name or an unknown muscle/equipment reference")
            }
            guard Set(entry.videos.map(\.id)).count == entry.videos.count else {
                throw invalid("exercise \(entry.id) has duplicate video identifiers")
            }
            for video in entry.videos {
                guard !video.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      !video.author.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      !video.license.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw invalid("video attribution is required")
                }
                for address in [video.url, video.licenseURL, video.sourceURL] {
                    guard let url = URLComponents(string: address), url.scheme?.lowercased() == "https",
                          let host = url.host, !host.isEmpty, url.user == nil, url.password == nil else {
                        throw invalid("video URLs must use HTTPS without credentials")
                    }
                }
            }
        }
    }
}
