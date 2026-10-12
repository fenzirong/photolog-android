import Foundation
import SwiftData
import PhotoLogKit

/// The library row.
///
/// Field for field the same as the Android `photos` table and the HarmonyOS `PhotoRecord`, so a
/// library exported from one platform lines up with the others.
///
/// **The bytes are not here.** `fileName` points at a file under `Application Support/originals`,
/// which holds exactly what the camera wrote or what the source app handed over. Keeping the
/// original untouched is what makes 无损导出 possible at all.
///
/// **`sortIndex` is the user's order, not a timestamp**, and it is a dense 1..n sequence:
/// reordering rewrites the whole list anyway, so "index equals position" is worth more than fewer
/// writes.
@Model
final class Photo {
    @Attribute(.unique) var id: UUID
    var caption: String
    var fileName: String
    var originalName: String
    var mimeType: String
    var width: Int
    var height: Int
    var sizeBytes: Int64
    var sha256: String
    var capturedAt: Date
    var addedAt: Date
    var source: String
    var sortIndex: Int64

    init(
        id: UUID = UUID(),
        caption: String = "",
        fileName: String,
        originalName: String = "",
        mimeType: String = "image/jpeg",
        width: Int = 0,
        height: Int = 0,
        sizeBytes: Int64 = 0,
        sha256: String = "",
        capturedAt: Date = Date(),
        addedAt: Date = Date(),
        source: String = "GALLERY",
        sortIndex: Int64 = 0
    ) {
        self.id = id
        self.caption = caption
        self.fileName = fileName
        self.originalName = originalName
        self.mimeType = mimeType
        self.width = width
        self.height = height
        self.sizeBytes = sizeBytes
        self.sha256 = sha256
        self.capturedAt = capturedAt
        self.addedAt = addedAt
        self.source = source
        self.sortIndex = sortIndex
    }

    /// The shape `PhotoLogKit` works from, so the export logic stays free of SwiftData.
    var record: PhotoRecord {
        PhotoRecord(
            id: 0,
            caption: caption,
            fileName: fileName,
            originalName: originalName,
            mimeType: mimeType,
            width: width,
            height: height,
            sizeBytes: sizeBytes,
            sha256: sha256,
            capturedAt: capturedAt,
            addedAt: addedAt,
            source: source,
            sortIndex: sortIndex
        )
    }
}

/// What the share extension drops into the App Group container.
///
/// A manifest plus copied files rather than a database write, because the extension is a separate
/// process: SwiftData in an app group is shared by file path and concurrent writers are a real
/// hazard, while a write-then-move inbox is not.
struct SharedItem: Codable {
    let fileName: String
    let originalName: String
    let mimeType: String
}

enum AppGroup {
    static let identifier = "group.io.photolog"

    static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
    }

    /// Where the extension leaves images for the app to pick up.
    static var inboxURL: URL? {
        guard let root = containerURL else { return nil }
        let inbox = root.appendingPathComponent("Inbox", isDirectory: true)
        try? FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        return inbox
    }
}

/// Drains the share inbox into the library.
enum ShareInbox {
    @MainActor
    static func drain(store: LibraryStore) async {
        guard let inbox = AppGroup.inboxURL else { return }
        let manager = FileManager.default
        guard let names = try? manager.contentsOfDirectory(atPath: inbox.path) else { return }

        let manifestURL = inbox.appendingPathComponent("manifest.json")
        var items: [SharedItem] = []
        if let data = try? Data(contentsOf: manifestURL),
           let decoded = try? JSONDecoder().decode([SharedItem].self, from: data) {
            items = decoded
        }

        for item in items {
            let source = inbox.appendingPathComponent(item.fileName)
            guard manager.fileExists(atPath: source.path) else { continue }
            await store.importFile(
                at: source,
                originalName: item.originalName,
                mimeType: item.mimeType,
                source: "SHARE"
            )
        }

        // Clear the inbox only after everything has been promoted, so an interrupted drain leaves
        // the items for the next launch rather than losing them.
        for name in names {
            try? manager.removeItem(at: inbox.appendingPathComponent(name))
        }
    }
}

/// Everything the user can change.
///
/// Field for field the same as the other two builds, including the defaults — which are the part
/// users notice.
struct AppSettings: Equatable {
    var themeMode: String = "system"
    var exportLossless: Bool = true
    var exportIncludeCaptions: Bool = true
    var exportCaptionFormat: CaptionFormat = .markdown
    var exportNumbered: Bool = true
    var exportNameFromCaption: Bool = true
    var exportJpegQuality: Double = 0.95
    var exportMaxLongEdge: Int = 4096

    var exportOptions: ExportOptions {
        ExportOptions(
            lossless: exportLossless,
            jpegQuality: exportJpegQuality,
            maxLongEdge: exportMaxLongEdge,
            includeCaptions: exportIncludeCaptions,
            captionFormat: exportCaptionFormat,
            numbered: exportNumbered,
            useCaptionAsName: exportNameFromCaption
        )
    }
}

/// `UserDefaults`-backed settings, read on the way in rather than written on first launch, so an
/// app that is never configured never has to touch disk.
@Observable
final class SettingsStore {
    private let defaults = UserDefaults.standard

    var themeMode: String {
        didSet { defaults.set(themeMode, forKey: "themeMode") }
    }
    var exportLossless: Bool {
        didSet { defaults.set(exportLossless, forKey: "exportLossless") }
    }
    var exportIncludeCaptions: Bool {
        didSet { defaults.set(exportIncludeCaptions, forKey: "exportIncludeCaptions") }
    }
    var exportNumbered: Bool {
        didSet { defaults.set(exportNumbered, forKey: "exportNumbered") }
    }
    var exportNameFromCaption: Bool {
        didSet { defaults.set(exportNameFromCaption, forKey: "exportNameFromCaption") }
    }
    var exportJpegQuality: Double {
        didSet { defaults.set(exportJpegQuality, forKey: "exportJpegQuality") }
    }
    var exportMaxLongEdge: Int {
        didSet { defaults.set(exportMaxLongEdge, forKey: "exportMaxLongEdge") }
    }
    var exportCaptionFormat: CaptionFormat {
        didSet { defaults.set(exportCaptionFormat.rawValue, forKey: "exportCaptionFormat") }
    }

    init() {
        let fallback = AppSettings()
        themeMode = defaults.string(forKey: "themeMode") ?? fallback.themeMode
        exportLossless = defaults.object(forKey: "exportLossless") as? Bool ?? fallback.exportLossless
        exportIncludeCaptions = defaults.object(forKey: "exportIncludeCaptions") as? Bool ?? fallback.exportIncludeCaptions
        exportNumbered = defaults.object(forKey: "exportNumbered") as? Bool ?? fallback.exportNumbered
        exportNameFromCaption = defaults.object(forKey: "exportNameFromCaption") as? Bool ?? fallback.exportNameFromCaption
        exportJpegQuality = defaults.object(forKey: "exportJpegQuality") as? Double ?? fallback.exportJpegQuality
        exportMaxLongEdge = defaults.object(forKey: "exportMaxLongEdge") as? Int ?? fallback.exportMaxLongEdge
        let storedFormat = defaults.string(forKey: "exportCaptionFormat") ?? fallback.exportCaptionFormat.rawValue
        exportCaptionFormat = CaptionFormat(rawValue: storedFormat) ?? .markdown
    }

    var settings: AppSettings {
        AppSettings(
            themeMode: themeMode,
            exportLossless: exportLossless,
            exportIncludeCaptions: exportIncludeCaptions,
            exportCaptionFormat: exportCaptionFormat,
            exportNumbered: exportNumbered,
            exportNameFromCaption: exportNameFromCaption,
            exportJpegQuality: exportJpegQuality,
            exportMaxLongEdge: exportMaxLongEdge
        )
    }
}
