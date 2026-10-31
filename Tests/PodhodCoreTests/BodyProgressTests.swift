import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import PodhodCore

final class BodyProgressTests: XCTestCase {
    private func location() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("BodyProgressQA-\(UUID())/body-progress.json")
    }

    private func entry() -> BodyMeasurementEntry {
        BodyMeasurementEntry(date: "2026-11-01", timezone: "Europe/Moscow", measurements: [
            BodyMeasurement(metric: .weight, value: 75.5), BodyMeasurement(metric: .waist, value: 80)
        ])
    }

    private func photo() -> BodyProgressPhoto { BodyProgressPhoto(date: "2026-11-01", timezone: "Europe/Moscow", angle: .front) }

    private func sourcePhoto(width: Int = 8, height: Int = 4) throws -> Data {
        let pixels = Data(repeating: 120, count: width * height * 4)
        let provider = try XCTUnwrap(CGDataProvider(data: pixels as CFData))
        let image = try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: provider,
            decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let bytes = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(bytes, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [
            kCGImagePropertyOrientation: 6,
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 0.0, kCGImagePropertyGPSLatitudeRef: "N",
                kCGImagePropertyGPSLongitude: 0.0, kCGImagePropertyGPSLongitudeRef: "E"],
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifUserComment: "Synthetic privacy test"]
        ] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return bytes as Data
    }

    func testMissingMetricsRemainUnknownAndGraphContainsOnlyMeasuredValues() {
        let first = entry()
        let second = BodyMeasurementEntry(date: "2026-11-02", timezone: "UTC", measurements: [.init(metric: .waist, value: 79)])
        let archive = BodyProgressArchive(entries: [second, first])
        XCTAssertTrue(archive.isValid)
        XCTAssertNil(second.value(for: .weight))
        XCTAssertEqual(archive.points(for: .weight).map(\.value), [75.5])
        XCTAssertEqual(archive.points(for: .waist).map { $0.entry.date }, ["2026-11-01", "2026-11-02"])
        for bad in [0.0, -1, .nan, .infinity, 1001] {
            XCTAssertFalse(BodyMeasurement(metric: .weight, value: bad).isValid)
        }
        XCTAssertFalse(BodyMeasurement(metric: .waist, value: 501).isValid)
    }

    func testDatesDuplicateMetricsAndArchiveIdentitiesAreValidated() {
        var record = entry()
        record.measurements.append(record.measurements[0])
        XCTAssertFalse(record.isValid)
        record = entry(); record.date = "2026-02-30"
        XCTAssertFalse(record.isValid)
        record = entry(); record.timezone = "Local"
        XCTAssertFalse(record.isValid)
        record = entry(); record.measurements = []
        XCTAssertFalse(record.isValid)
        XCTAssertFalse(BodyProgressArchive(entries: [entry(), entry()]).isValid)
        let picture = photo()
        XCTAssertFalse(BodyProgressArchive(photos: [picture], pendingPhotoDeletions: [picture.id]).isValid)
    }

    func testPhotoPreparationStripsSourceGPSAndExifAndAppliesOrientation() throws {
        let original = try sourcePhoto(width: 4096, height: 4)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(original as CFData, nil))
        let before = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        XCTAssertNotNil(before[kCGImagePropertyGPSDictionary])
        XCTAssertFalse(ProgressPhotoImport.isPreparedJPEG(original))
        let prepared = try ProgressPhotoImport.prepare(original)
        XCTAssertTrue(ProgressPhotoImport.isPreparedJPEG(prepared))
        let output = try XCTUnwrap(CGImageSourceCreateWithData(prepared as CFData, nil))
        let after = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(output, 0, nil) as? [CFString: Any])
        XCTAssertNil(after[kCGImagePropertyGPSDictionary])
        let exif = try XCTUnwrap(after[kCGImagePropertyExifDictionary] as? [CFString: Any])
        XCTAssertEqual(Set(exif.keys), Set([kCGImagePropertyExifPixelXDimension, kCGImagePropertyExifPixelYDimension,
            kCGImagePropertyExifColorSpace]))
        XCTAssertEqual((exif[kCGImagePropertyExifColorSpace] as? NSNumber)?.intValue, 1)
        XCTAssertNil(exif[kCGImagePropertyExifUserComment])
        XCTAssertEqual((after[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue, 2048)
        XCTAssertLessThan((after[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 9999, 2048)
        XCTAssertThrowsError(try ProgressPhotoImport.prepare(Data("not an image".utf8)))
        XCTAssertFalse(ProgressPhotoImport.isPreparedJPEG(Data()))
    }

    @MainActor func testMeasurementsSaveRestartAndRejectStaleOrOccupiedDates() async throws {
        let store = BodyProgressStore(fileURL: location())
        let first = entry()
        XCTAssertTrue(store.saveEntry(first, expected: nil))
        var changed = first
        changed.measurements[0].value = 76
        XCTAssertTrue(store.saveEntry(changed, expected: first))
        XCTAssertFalse(store.saveEntry(first, expected: first))
        var collision = first; collision.id = UUID()
        XCTAssertFalse(store.saveEntry(collision, expected: nil))
        var wrongDate = changed; wrongDate.date = "2026-11-02"
        XCTAssertFalse(store.saveEntry(wrongDate, expected: changed))
        XCTAssertEqual(BodyProgressStore(fileURL: store.fileURL).entry(on: first.date), changed)
        XCTAssertTrue(store.removeEntry(changed))
        XCTAssertFalse(store.removeEntry(changed))
        XCTAssertTrue(BodyProgressStore(fileURL: store.fileURL).archive.entries.isEmpty)
    }

    @MainActor func testPreparedPhotosPersistAndOnlyRegisteredIDsCanBeRead() async throws {
        let store = BodyProgressStore(fileURL: location())
        let jpeg = try ProgressPhotoImport.prepare(sourcePhoto())
        let picture = photo()
        XCTAssertFalse(store.addPhoto(picture, preparedJPEG: try sourcePhoto()))
        XCTAssertTrue(store.addPhoto(picture, preparedJPEG: jpeg))
        XCTAssertEqual(try store.photoData(for: picture.id), jpeg)
        XCTAssertThrowsError(try store.photoData(for: UUID()))
        XCTAssertFalse(store.addPhoto(picture, preparedJPEG: jpeg))
        let restored = BodyProgressStore(fileURL: store.fileURL)
        XCTAssertEqual(restored.archive.photos, [picture])
        XCTAssertEqual(try restored.photoData(for: picture.id), jpeg)
        XCTAssertTrue(restored.removePhoto(picture))
        XCTAssertTrue(restored.archive.photos.isEmpty)
        XCTAssertFalse(restored.hasPendingDeletions)
        XCTAssertThrowsError(try restored.photoData(for: picture.id))
    }

    @MainActor func testFailedManifestWriteRollsBackOnlyNewPhoto() async throws {
        let store = BodyProgressStore(fileURL: location())
        try FileManager.default.createDirectory(at: store.fileURL, withIntermediateDirectories: true)
        let picture = photo()
        XCTAssertFalse(store.addPhoto(picture, preparedJPEG: try ProgressPhotoImport.prepare(sourcePhoto())))
        let path = store.fileURL.deletingLastPathComponent().appendingPathComponent("progress-photos/\(picture.id.uuidString).jpg")
        XCTAssertFalse(FileManager.default.fileExists(atPath: path.path))
        XCTAssertTrue(store.archive.photos.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.fileURL.path))
    }

    @MainActor func testDeletionJournalSurvivesFailureAndRetriesAfterRestart() async throws {
        let store = BodyProgressStore(fileURL: location())
        let picture = photo(), jpeg = try ProgressPhotoImport.prepare(sourcePhoto())
        XCTAssertTrue(store.addPhoto(picture, preparedJPEG: jpeg))
        let path = store.fileURL.deletingLastPathComponent().appendingPathComponent("progress-photos/\(picture.id.uuidString).jpg")
        try FileManager.default.removeItem(at: path)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        XCTAssertFalse(store.removePhoto(picture))
        XCTAssertTrue(store.archive.photos.isEmpty)
        XCTAssertEqual(store.archive.pendingPhotoDeletions, [picture.id])
        let restored = BodyProgressStore(fileURL: store.fileURL)
        XCTAssertFalse(restored.loadFailed)
        XCTAssertEqual(restored.archive.pendingPhotoDeletions, [picture.id])
        try FileManager.default.removeItem(at: path)
        try jpeg.write(to: path)
        XCTAssertTrue(restored.retryPendingPhotoDeletions())
        XCTAssertFalse(FileManager.default.fileExists(atPath: path.path))
        XCTAssertFalse(BodyProgressStore(fileURL: store.fileURL).hasPendingDeletions)
    }

    @MainActor func testMissingPhotoDoesNotEraseMeasurementsOrReplaceImage() async throws {
        let store = BodyProgressStore(fileURL: location())
        let picture = photo()
        XCTAssertTrue(store.saveEntry(entry(), expected: nil))
        XCTAssertTrue(store.addPhoto(picture, preparedJPEG: try ProgressPhotoImport.prepare(sourcePhoto())))
        try FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent().appendingPathComponent("progress-photos/\(picture.id.uuidString).jpg"))
        let restored = BodyProgressStore(fileURL: store.fileURL)
        XCTAssertFalse(restored.loadFailed)
        XCTAssertEqual(restored.archive.entries, store.archive.entries)
        XCTAssertEqual(restored.archive.photos, [picture])
        XCTAssertThrowsError(try restored.photoData(for: picture.id))
        XCTAssertTrue(restored.removePhoto(picture))
        XCTAssertFalse(restored.hasPendingDeletions)
    }

    @MainActor func testForeignOwnerAndRetiredWorkspaceRejectWritesAndPhotoReads() async throws {
        let url = location()
        let owner = BodyProgressStore(fileURL: url, accountID: "owner-a")
        XCTAssertTrue(owner.saveEntry(entry(), expected: nil))
        let picture = photo()
        XCTAssertTrue(owner.addPhoto(picture, preparedJPEG: try ProgressPhotoImport.prepare(sourcePhoto())))
        let original = try Data(contentsOf: url)
        for other in [nil, "owner-b"] {
            let store = BodyProgressStore(fileURL: url, accountID: other)
            XCTAssertTrue(store.loadFailed)
            XCTAssertFalse(store.saveEntry(entry(), expected: nil))
            XCTAssertThrowsError(try store.photoData(for: picture.id))
        }
        owner.retire()
        XCTAssertFalse(owner.removePhoto(picture))
        XCTAssertThrowsError(try owner.photoData(for: picture.id))
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    @MainActor func testFutureCorruptAndPathTraversalArchivesStayUnchanged() async throws {
        for text in [
            "not JSON", #"{"version":2,"entries":[],"photos":[],"pendingPhotoDeletions":[]}"#,
            #"{"version":1,"entries":[],"photos":[{"id":"../../foreign.jpg","date":"2026-11-01","timezone":"UTC","angle":"front"}],"pendingPhotoDeletions":[]}"#
        ] {
            let url = location(), original = Data(text.utf8)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try original.write(to: url)
            let store = BodyProgressStore(fileURL: url)
            XCTAssertTrue(store.loadFailed)
            XCTAssertFalse(store.saveEntry(entry(), expected: nil))
            XCTAssertEqual(try Data(contentsOf: url), original)
        }
    }

    @MainActor func testSymlinkPhotoDirectoryIsProtected() async throws {
        let url = location(), outside = location().deletingLastPathComponent()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let link = url.deletingLastPathComponent().appendingPathComponent("progress-photos")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let store = BodyProgressStore(fileURL: url)
        XCTAssertTrue(store.loadFailed)
        XCTAssertFalse(store.addPhoto(photo(), preparedJPEG: try ProgressPhotoImport.prepare(sourcePhoto())))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
    }

    func testGridPreviewUsesSmallPixelsAndKeepsSourceUntouched() throws {
        let original = try ProgressPhotoImport.prepare(sourcePhoto(width: 4096, height: 4))
        let preview = try ProgressPhotoImport.preview(original, maximumDimension: 400)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(preview as CFData, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        XCTAssertEqual((properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue, 400)
        XCTAssertTrue(ProgressPhotoImport.isPreparedJPEG(preview))
        XCTAssertEqual(try ProgressPhotoImport.preview(original, maximumDimension: 2048), original)
        XCTAssertThrowsError(try ProgressPhotoImport.preview(original, maximumDimension: 0))
    }

    @MainActor func testCancelledPhotoPreparationDoesNotContinueIntoDecode() async {
        let task = Task { try await ProgressPhotoPreparation.shared.prepare(Data("not an image".utf8)) }
        task.cancel()
        do { _ = try await task.value; XCTFail("cancelled import completed") }
        catch is CancellationError {} catch { XCTFail("cancellation was ignored: \(error)") }
    }
}
