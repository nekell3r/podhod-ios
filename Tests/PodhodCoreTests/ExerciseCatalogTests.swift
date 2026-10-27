import XCTest
@testable import PodhodCore

final class ExerciseCatalogTests: XCTestCase {
    private let knownID = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!

    private func document(primary: [String] = ["chest"], secondary: [String] = ["triceps"]) -> [String: Any] {
        [
            "version": "test-1",
            "muscles": [["id": "chest", "name": "Грудь"], ["id": "triceps", "name": "Трицепс"]],
            "equipment": [["id": "barbell", "name": "Штанга"]],
            "exercises": [[
                "exercise": ["id": knownID.uuidString, "name": "Жим штанги лёжа", "muscle": "Грудь", "illustration": "bench", "cue": "Тест"],
                "aliases": ["Bench press"], "primaryMuscles": primary, "secondaryMuscles": secondary,
                "equipment": ["barbell"], "instructions": ["Тестовая инструкция"], "videos": [],
                "sourceURL": "", "attribution": ["author": "Тест", "license": "", "licenseURL": "", "sourceURL": ""]
            ]]
        ]
    }

    private func catalog(primary: [String] = ["chest"], secondary: [String] = ["triceps"]) throws -> ExerciseCatalog {
        try ExerciseCatalog(data: JSONSerialization.data(withJSONObject: document(primary: primary, secondary: secondary)))
    }

    func testSearchFindsRussianNamesEnglishAliasesAndCombinedFilters() throws {
        let catalog = try catalog()
        XCTAssertEqual(catalog.search(query: "  ЖИМ ШТАНГИ ЛЕЖА  ").map(\.id), [knownID])
        XCTAssertEqual(catalog.search(query: "BENCH").map(\.id), [knownID])
        XCTAssertEqual(catalog.search(query: "грудь").map(\.id), [knownID])
        XCTAssertEqual(catalog.search(query: "штанга").map(\.id), [knownID])
        XCTAssertEqual(catalog.search(muscleID: "triceps", equipmentID: "barbell").map(\.id), [knownID])
        XCTAssertTrue(catalog.search(muscleID: "unknown").isEmpty)
        XCTAssertTrue(catalog.search(query: "bench", equipmentID: "dumbbell").isEmpty)
        XCTAssertTrue(catalog.search(query: "несуществующее").isEmpty)
        XCTAssertNil(catalog.entry(for: UUID()))
    }

    func testExactIDAliasesResolveMetadataAndVolumeWithoutDuplicatingSearchOrChangingSnapshots() throws {
        XCTAssertTrue(try catalog().exerciseIDAliases.isEmpty)
        let aliasID = UUID(uuidString: "10000000-0000-4000-8000-000000000001")!
        var value = document()
        value["exerciseIDAliases"] = [["id": aliasID.uuidString, "exerciseID": knownID.uuidString]]
        let catalog = try ExerciseCatalog(data: JSONSerialization.data(withJSONObject: value))
        let canonical = try XCTUnwrap(catalog.entry(for: knownID))
        XCTAssertEqual(catalog.entry(for: aliasID), canonical)
        XCTAssertEqual(catalog.search().map(\.id), [knownID])
        XCTAssertEqual(catalog.search(query: "bench").map(\.id), [knownID])
        let snapshot = Exercise(id: aliasID, name: "Имя из сохранённого плана", muscle: "Сохранённая группа", illustration: "bench", cue: "Тестовая подсказка")
        let plan = PlannedExercise(exercise: snapshot, setCount: 3)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let original = try encoder.encode(plan)
        XCTAssertEqual(catalog.volume(for: [plan]), catalog.volume(for: [PlannedExercise(exercise: canonical.exercise, setCount: 3)]))
        XCTAssertEqual(catalog.volume(for: [plan]).unmappedExerciseCount, 0)
        XCTAssertEqual(plan.exercise.id, aliasID)
        XCTAssertEqual(try encoder.encode(plan), original)
        var blankArt = snapshot
        blankArt.illustration = ""
        XCTAssertEqual(catalog.illustration(for: blankArt), "bench")
        XCTAssertEqual(blankArt.illustration, "")
        blankArt.illustration = "row"
        XCTAssertEqual(catalog.illustration(for: blankArt), "row")
        let unknown = Exercise(name: "Тест", muscle: "", illustration: "", cue: "")
        XCTAssertEqual(catalog.illustration(for: unknown), "")
    }

    func testAliasResourceRejectsDuplicatesCanonicalCollisionsMissingTargetsAndChains() throws {
        let aliasID = "10000000-0000-4000-8000-000000000001"
        let otherAliasID = "10000000-0000-4000-8000-000000000002"
        let canonicalID = knownID.uuidString
        let invalidAliases = [
            [["id": aliasID, "exerciseID": canonicalID], ["id": aliasID, "exerciseID": canonicalID]],
            [["id": canonicalID, "exerciseID": canonicalID]],
            [["id": aliasID, "exerciseID": otherAliasID]],
            [["id": aliasID, "exerciseID": otherAliasID], ["id": otherAliasID, "exerciseID": canonicalID]],
            [["id": aliasID, "exerciseID": aliasID]],
            [["id": "not-a-uuid", "exerciseID": canonicalID]]
        ]
        for aliases in invalidAliases {
            var value = document()
            value["exerciseIDAliases"] = aliases
            XCTAssertThrowsError(try ExerciseCatalog(data: JSONSerialization.data(withJSONObject: value)))
        }
    }

    func testWeightedVolumeDeduplicatesMusclesAndPrimaryWins() throws {
        let catalog = try catalog(primary: ["chest", "chest"], secondary: ["chest", "triceps", "triceps"])
        let exercise = try XCTUnwrap(catalog.entry(for: knownID)).exercise
        let volume = catalog.volume(for: [PlannedExercise(exercise: exercise, setCount: 3)])
        XCTAssertEqual(volume.catalogVersion, "test-1")
        XCTAssertEqual(volume.totalSets, 3)
        XCTAssertEqual(volume.muscles, [
            MuscleSetVolume(id: "chest", name: "Грудь", directSets: 3, indirectSets: 0),
            MuscleSetVolume(id: "triceps", name: "Трицепс", directSets: 0, indirectSets: 3)
        ])
        XCTAssertEqual(volume.muscles.map(\.weightedSets), [3, 1.5])
        XCTAssertEqual(volume.unmappedExerciseCount, 0)
        XCTAssertEqual(volume.unmappedSets, 0)
    }

    func testUnknownCustomExercisesNeverInferMusclesFromDisplayLabel() throws {
        let catalog = try catalog()
        let known = try XCTUnwrap(catalog.entry(for: knownID)).exercise
        let custom = Exercise(name: "Свой жим", muscle: "Грудь", illustration: "bench", cue: "")
        let volume = catalog.volume(for: [
            PlannedExercise(exercise: known, setCount: 2),
            PlannedExercise(exercise: custom, setCount: 4),
            PlannedExercise(exercise: custom, setCount: 3)
        ])
        XCTAssertEqual(volume.muscles.first?.directSets, 2)
        XCTAssertEqual(volume.unmappedExerciseCount, 2)
        XCTAssertEqual(volume.unmappedSets, 7)
        XCTAssertEqual(volume.totalSets, 9)
        let unclassified = try self.catalog(primary: [], secondary: [])
        XCTAssertEqual(unclassified.volume(for: [PlannedExercise(exercise: known)]).unmappedSets, 3)
    }

    func testDayDatedWeekAndTemplateSumOnlyPlannedWorkingSets() throws {
        let catalog = try catalog()
        let exercise = try XCTUnwrap(catalog.entry(for: knownID)).exercise
        let monday = TrainingDay(weekday: 1, title: "Первый", exercises: [PlannedExercise(exercise: exercise, setCount: 3)])
        let friday = TrainingDay(weekday: 5, title: "Второй", exercises: [PlannedExercise(exercise: exercise, setCount: 4)])
        let calendar = TrainingCalendar(timezone: "UTC")
        let date = try XCTUnwrap(calendar.date(from: "2026-10-26"))
        let week = TrainingWeek(containing: date, template: [monday, friday], calendar: calendar)
        XCTAssertEqual(catalog.volume(for: monday).muscles.map(\.weightedSets), [3, 1.5])
        XCTAssertEqual(catalog.volume(for: week), catalog.volume(for: [monday, friday]))
        XCTAssertEqual(catalog.volume(for: week).muscles.map(\.weightedSets), [7, 3.5])
        XCTAssertEqual(catalog.volume(for: week).totalSets, 7)
        XCTAssertTrue(catalog.volume(for: [PlannedExercise]()).muscles.isEmpty)
        XCTAssertEqual(catalog.volume(for: [PlannedExercise]()).unmappedSets, 0)
    }

    func testResourceRejectsUnknownReferencesAndDuplicateIdentifiers() throws {
        var value = document(primary: ["missing"])
        XCTAssertThrowsError(try ExerciseCatalog(data: JSONSerialization.data(withJSONObject: value)))
        value = document()
        value["exercises"] = [try XCTUnwrap((value["exercises"] as? [[String: Any]])?.first),
                              try XCTUnwrap((value["exercises"] as? [[String: Any]])?.first)]
        XCTAssertThrowsError(try ExerciseCatalog(data: JSONSerialization.data(withJSONObject: value)))
        value = document()
        value["equipment"] = [["id": "barbell", "name": "Штанга"], ["id": "barbell", "name": "Дубликат"]]
        XCTAssertThrowsError(try ExerciseCatalog(data: JSONSerialization.data(withJSONObject: value)))
        value = document()
        value["version"] = " "
        XCTAssertThrowsError(try ExerciseCatalog(data: JSONSerialization.data(withJSONObject: value)))
    }

    func testResourceRejectsUnsafeVideoURLAndMissingAttribution() throws {
        var value = document()
        var entries = try XCTUnwrap(value["exercises"] as? [[String: Any]])
        var video = ["id": "fixture-video", "url": "https://example.invalid/video.mp4", "author": "Fixture",
                     "license": "CC-BY-SA-4.0", "licenseURL": "https://example.invalid/license", "sourceURL": "https://example.invalid/source"]
        entries[0]["videos"] = [video]
        value["exercises"] = entries
        let originalVideo = try ExerciseCatalog(data: JSONSerialization.data(withJSONObject: value)).exercises[0].videos[0]
        XCTAssertNil(originalVideo.playback)
        video["playback"] = "external"
        entries[0]["videos"] = [video]
        value["exercises"] = entries
        XCTAssertEqual(try ExerciseCatalog(data: JSONSerialization.data(withJSONObject: value)).exercises[0].videos[0].playback, .external)
        video["playback"] = "unsupported-mode"
        entries[0]["videos"] = [video]
        value["exercises"] = entries
        XCTAssertThrowsError(try ExerciseCatalog(data: JSONSerialization.data(withJSONObject: value)))
        video.removeValue(forKey: "playback")
        for address in ["http://example.invalid/video.mp4", "https://user:password@example.invalid/video.mp4", "file:///video.mp4"] {
            video["url"] = address
            entries[0]["videos"] = [video]
            value["exercises"] = entries
            XCTAssertThrowsError(try ExerciseCatalog(data: JSONSerialization.data(withJSONObject: value)))
        }
        video["url"] = "https://example.invalid/video.mp4"
        video["author"] = " "
        entries[0]["videos"] = [video]
        value["exercises"] = entries
        XCTAssertThrowsError(try ExerciseCatalog(data: JSONSerialization.data(withJSONObject: value)))
    }

    func testBundledCatalogPreservesTwelveLegacyIdentitiesAndOrdering() throws {
        let catalog = ExerciseCatalog.bundled
        XCTAssertGreaterThanOrEqual(catalog.exercises.count, 12)
        let names = ["Жим штанги лёжа", "Приседания со штангой", "Тяга верхнего блока", "Румынская тяга",
                     "Жим гантелей сидя", "Горизонтальная тяга", "Сгибания с гантелями", "Разгибания на блоке",
                     "Жим ногами", "Выпады с гантелями", "Разведения гантелей", "Подтягивания"]
        for index in 0..<12 {
            let id = try XCTUnwrap(UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", index + 1)))
            XCTAssertEqual(catalog.exercises[index].id, id)
            XCTAssertEqual(catalog.exercises[index].exercise.name, names[index])
            XCTAssertNotNil(catalog.entry(for: id))
        }
        XCTAssertEqual(Exercise.catalog.map(\.id), catalog.exercises.map(\.id))
        let originalSnapshot = Exercise(id: knownID, name: "Старое имя из версии 1.2", muscle: "Старая группа", illustration: "bench", cue: "Старая подсказка")
        let plan = PlannedExercise(exercise: originalSnapshot, setCount: 3)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let original = try encoder.encode(plan)
        let volume = catalog.volume(for: [plan])
        XCTAssertEqual(volume.unmappedExerciseCount, 0)
        XCTAssertFalse(volume.muscles.isEmpty)
        XCTAssertEqual(try encoder.encode(plan), original)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(originalSnapshot)) as? [String: Any])
        XCTAssertEqual(Set(object.keys), Set(["id", "name", "muscle", "illustration", "cue"]))
    }

    @MainActor func testLibraryKeepsCustomExercisesFromDatedPlansActiveAndHistory() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("PodhodCatalogTests-\(UUID())/training.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let dated = Exercise(name: "Только в конкретной неделе", muscle: "Грудь", illustration: "bench", cue: "")
        let active = Exercise(name: "Только в активной", muscle: "Грудь", illustration: "bench", cue: "")
        let past = Exercise(name: "Только в истории", muscle: "Грудь", illustration: "bench", cue: "")
        let calendar = TrainingCalendar(timezone: "UTC")
        let date = try XCTUnwrap(calendar.date(from: "2026-10-26"))
        let datedDay = TrainingDay(weekday: 1, title: "План", exercises: [PlannedExercise(exercise: dated)])
        let activeDay = TrainingDay(weekday: 2, title: "Активная", exercises: [PlannedExercise(exercise: active)])
        let pastDay = TrainingDay(weekday: 3, title: "История", exercises: [PlannedExercise(exercise: past)])
        var archive = TrainingArchive()
        archive.scheduledWeeks = [TrainingWeek(containing: date, template: [datedDay], calendar: calendar)]
        archive.active = WorkoutSession(day: activeDay, date: date)
        var history = WorkoutSession(day: pastDay, date: date)
        history.finishedAt = date.addingTimeInterval(600)
        archive.history = [history]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = try JSONEncoder().encode(archive)
        try original.write(to: url)
        let store = WorkoutStore(fileURL: url)
        let library = store.exerciseLibrary
        for id in [dated.id, active.id, past.id] { XCTAssertEqual(library.filter { $0.id == id }.count, 1) }
        XCTAssertEqual(store.archive, archive)
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    @MainActor func testLibraryRemovesMappedDuplicatesWhileSavedIdentityAndSnapshotsRemainUnchanged() async throws {
        let catalog = ExerciseCatalog.bundled
        let alias = try XCTUnwrap(catalog.exerciseIDAliases.first)
        let canonical = try XCTUnwrap(catalog.entry(for: alias.id))
        let snapshot = Exercise(id: alias.id, name: "Тестовое сохранённое имя", muscle: "Тестовая группа", illustration: "bench", cue: "Тестовая подсказка")
        let day = TrainingDay(weekday: 1, title: "Тест", exercises: [PlannedExercise(exercise: snapshot)])
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("PodhodCatalogAliasTests-\(UUID())/training.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let calendar = TrainingCalendar(timezone: "UTC")
        let date = try XCTUnwrap(calendar.date(from: "2026-10-26"))
        var archive = TrainingArchive()
        archive.week[0] = day
        archive.scheduledWeeks = [TrainingWeek(containing: date, template: [day], calendar: calendar)]
        archive.active = WorkoutSession(day: day, date: date)
        var history = WorkoutSession(day: day, date: date)
        history.finishedAt = date.addingTimeInterval(600)
        archive.history = [history]
        let original = try JSONEncoder().encode(archive)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try original.write(to: url)
        let store = WorkoutStore(fileURL: url)
        XCTAssertEqual(store.exerciseLibrary.filter { $0.id == canonical.id }.count, 1)
        XCTAssertFalse(store.exerciseLibrary.contains { $0.id == alias.id })
        XCTAssertEqual(store.archive, archive)
        XCTAssertEqual(try Data(contentsOf: url), original)
    }
}
