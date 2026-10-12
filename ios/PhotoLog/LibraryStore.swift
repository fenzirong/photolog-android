import Foundation
import SwiftData
import CryptoKit
import ImageIO
import PhotoLogKit

/// The library: the files, and the rows that index them.
///
/// The only place in the app that knows where the originals live, which is what keeps the "never
/// re-encode the original" rule enforceable — the export path can only read bytes through
/// `url(for:)`, so it cannot accidentally overwrite the source.
@MainActor
@Observable
final class LibraryStore {
    private let context: ModelContext
    private let fileManager = FileManager.default

    /// Bumped after every mutation so views re-read rather than each holding its own copy.
    var revision: Int = 0

    init(context: ModelContext) {
        self.context = context
    }

    /// Where the originals live.
    ///
    /// `Application Support` rather than `Documents`: these files are the app's own data, not
    /// something the user browses in Files, and `Documents` is exposed there by default.
    var originalsDirectory: URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("originals", isDirectory: true)
        if !fileManager.fileExists(atPath: dir.path) {
            try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    func url(for photo: Photo) -> URL {
        originalsDirectory.appendingPathComponent(photo.fileName)
    }

    /// The untouched original. Read-only by convention — nothing in this app writes to it.
    func data(for photo: Photo) throws -> Data {
        try Data(contentsOf: url(for: photo))
    }

    func allPhotos() -> [Photo] {
        let descriptor = FetchDescriptor<Photo>(sortBy: [SortDescriptor(\.sortIndex, order: .forward)])
        return (try? context.fetch(descriptor)) ?? []
    }

    func count() -> Int {
        (try? context.fetchCount(FetchDescriptor<Photo>())) ?? 0
    }

    func totalBytes() -> Int64 {
        allPhotos().reduce(0) { $0 + $1.sizeBytes }
    }

    /// Reserves a path for the camera to write into, before the capture starts.
    func newCaptureURL() -> URL {
        let stamp = Self.stamp(Date())
        var candidate = originalsDirectory.appendingPathComponent("c_\(stamp).jpg")
        var suffix = 1
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = originalsDirectory.appendingPathComponent("c_\(stamp)_\(suffix).jpg")
            suffix += 1
        }
        return candidate
    }

    // MARK: - import

    /// Copies one image into the library.
    ///
    /// The file is written to a temporary location first, hashing as it goes, and only then
    /// promoted into `originals`. Two consequences are deliberate: nothing half-written can become
    /// a library entry, and the duplicate check runs before the copy is promoted — so re-importing
    /// the same image costs a hash rather than a second copy on disk.
    @discardableResult
    func importFile(
        at source: URL,
        originalName: String,
        mimeType: String,
        source sourceKind: String
    ) async -> Photo? {
        let temp = fileManager.temporaryDirectory
            .appendingPathComponent("photolog-import-\(UUID().uuidString)")

        do {
            let data = try Data(contentsOf: source)
            guard !data.isEmpty else { return nil }
            try data.write(to: temp)

            let sha = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            if let existing = findByHash(sha) {
                try? fileManager.removeItem(at: temp)
                return existing
            }

            let target = allocate(prefix: "g", extension: extensionForMime(mimeType))
            try fileManager.moveItem(at: temp, to: target)

            let size = imageSize(at: target)
            let now = Date()
            let photo = Photo(
                caption: "",
                fileName: target.lastPathComponent,
                originalName: originalName,
                mimeType: mimeType,
                width: size.width,
                height: size.height,
                sizeBytes: Int64(data.count),
                sha256: sha,
                capturedAt: now,
                addedAt: now,
                source: sourceKind,
                sortIndex: nextSortIndex()
            )
            context.insert(photo)
            try? context.save()
            revision += 1
            return photo
        } catch {
            try? fileManager.removeItem(at: temp)
            return nil
        }
    }

    /// Builds the row for a file the camera already wrote.
    ///
    /// The hash is left empty: the camera path is the one place the bytes are known to be new, and
    /// hashing a 12 MP JPEG here would delay the shutter. Duplicate detection therefore does not
    /// apply to camera captures, which is correct — taking the same photo twice is two photos.
    @discardableResult
    func registerCapture(at url: URL) -> Photo? {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? Int64 else {
            return nil
        }
        let pixels = imageSize(at: url)
        let now = Date()
        let photo = Photo(
            caption: "",
            fileName: url.lastPathComponent,
            originalName: "",
            mimeType: "image/jpeg",
            width: pixels.width,
            height: pixels.height,
            sizeBytes: size,
            sha256: "",
            capturedAt: now,
            addedAt: now,
            source: "CAMERA",
            sortIndex: nextSortIndex()
        )
        context.insert(photo)
        try? context.save()
        revision += 1
        return photo
    }

    // MARK: - edits

    func setCaption(_ photo: Photo, to caption: String) {
        photo.caption = caption
        try? context.save()
        revision += 1
    }

    /// Moves one photo `delta` places in the user's order.
    ///
    /// The whole list is renumbered rather than swapping two values: swapping is only correct while
    /// every `sortIndex` is distinct, and one row left at 0 by an interrupted write would turn a
    /// swap into a silent no-op.
    func move(_ photo: Photo, by delta: Int) {
        var ordered = allPhotos()
        guard let from = ordered.firstIndex(where: { $0.id == photo.id }) else { return }
        let to = min(max(from + delta, 0), ordered.count - 1)
        guard to != from else { return }
        let moved = ordered.remove(at: from)
        ordered.insert(moved, at: to)
        for (index, item) in ordered.enumerated() {
            item.sortIndex = Int64(index + 1)
        }
        try? context.save()
        revision += 1
    }

    func sortByCapturedAt() {
        let ordered = allPhotos().sorted { $0.capturedAt < $1.capturedAt }
        for (index, item) in ordered.enumerated() {
            item.sortIndex = Int64(index + 1)
        }
        try? context.save()
        revision += 1
    }

    func delete(_ photos: [Photo]) {
        for photo in photos {
            try? fileManager.removeItem(at: url(for: photo))
            context.delete(photo)
        }
        try? context.save()
        renumber()
        revision += 1
    }

    func deleteAll() {
        for photo in allPhotos() {
            context.delete(photo)
        }
        try? context.save()
        if let entries = try? fileManager.contentsOfDirectory(atPath: originalsDirectory.path) {
            for entry in entries {
                try? fileManager.removeItem(at: originalsDirectory.appendingPathComponent(entry))
            }
        }
        revision += 1
    }

    // MARK: - helpers

    private func findByHash(_ sha: String) -> Photo? {
        guard !sha.isEmpty else { return nil }
        var descriptor = FetchDescriptor<Photo>(predicate: #Predicate { $0.sha256 == sha })
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first
    }

    private func renumber() {
        let ordered = allPhotos()
        for (index, item) in ordered.enumerated() {
            item.sortIndex = Int64(index + 1)
        }
        try? context.save()
    }

    private func nextSortIndex() -> Int64 {
        (allPhotos().map(\.sortIndex).max() ?? 0) + 1
    }

    private func allocate(prefix: String, extension ext: String) -> URL {
        let stamp = Self.stamp(Date())
        var candidate = originalsDirectory.appendingPathComponent("\(prefix)_\(stamp).\(ext)")
        var suffix = 1
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = originalsDirectory.appendingPathComponent("\(prefix)_\(stamp)_\(suffix).\(ext)")
            suffix += 1
        }
        return candidate
    }

    /// Pixel dimensions from the image header only — `CGImageSource` does not decode the pixels
    /// until asked, so this costs a header read rather than a full decode of a 12 MP photo.
    private func imageSize(at url: URL) -> (width: Int, height: Int) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else {
            return (0, 0)
        }
        return (width, height)
    }

    private static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd_HHmmss_SSS"
        return formatter.string(from: date)
    }
}
