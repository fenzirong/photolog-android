import Foundation
import SwiftUI
import UniformTypeIdentifiers
import PhotoLogKit

/// The archive handed to SwiftUI's `.fileExporter`.
///
/// `FileDocument` is the mechanism the system provides for "save this somewhere the user picks" —
/// the equivalent of Android's Storage Access Framework and HarmonyOS's `DocumentViewPicker`, and
/// like both of them it needs no storage permission of its own.
struct ExportedArchive: FileDocument {
    static var readableContentTypes: [UTType] { [.zip, .plainText, .html] }

    var data: Data
    var suggestedName: String

    init(data: Data, suggestedName: String) {
        self.data = data
        self.suggestedName = suggestedName
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
        suggestedName = "图志导出"
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

enum ExportFailure: LocalizedError {
    case nothingToExport

    var errorDescription: String? {
        switch self {
        case .nothingToExport: return "没有符合条件的照片"
        }
    }
}

/// Writes the library out.
///
/// Both output paths copy the stored original byte for byte and never decode it, so the 无损
/// guarantee holds identically in either.
enum Exporter {
    /// The whole library as one ZIP: images plus the caption document, in library order.
    static func makeArchive(
        photos: [Photo],
        store: LibraryStore,
        scope: ExportScope,
        options: ExportOptions
    ) throws -> ExportedArchive {
        let plan = ExportNaming.plan(photos: photos.map(\.record), scope: scope, options: options)
        guard !plan.isEmpty else { throw ExportFailure.nothingToExport }

        let byFileName = Dictionary(uniqueKeysWithValues: photos.map { ($0.fileName, $0) })
        var entries: [ZipWriter.Entry] = []
        for entry in plan {
            guard let photo = byFileName[entry.photo.fileName] else { continue }
            let url = store.url(for: photo)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            let size = (attributes?[.size] as? NSNumber)?.intValue ?? 0
            entries.append(
                ZipWriter.Entry(
                    name: "\(ExportNaming.imagesDir)/\(entry.name)",
                    size: size,
                    // Read at write time rather than held in memory: a library of 48 MP photos
                    // would not fit in RAM.
                    bytes: { (try? Data(contentsOf: url)) ?? Data() }
                )
            )
        }

        if options.includeCaptions {
            let document = CaptionDocument.build(plan: plan, options: options, exportedAt: Date())
            entries.append(
                ZipWriter.Entry(name: options.captionFormat.fileName, data: Data(document.utf8))
            )
        }

        let archive = ZipWriter.archive(entries: entries, modifiedAt: Date())
        return ExportedArchive(data: archive, suggestedName: "图志导出.zip")
    }

    /// Loose images plus the caption document, named by their captions.
    ///
    /// This is the export to keep: the result is browsable, editable, and re-importable.
    static func looseItems(
        photos: [Photo],
        store: LibraryStore,
        scope: ExportScope,
        options: ExportOptions
    ) throws -> [ExportedArchive] {
        let plan = ExportNaming.plan(photos: photos.map(\.record), scope: scope, options: options)
        guard !plan.isEmpty else { throw ExportFailure.nothingToExport }

        let byFileName = Dictionary(uniqueKeysWithValues: photos.map { ($0.fileName, $0) })
        var items: [ExportedArchive] = []
        for entry in plan {
            guard let photo = byFileName[entry.photo.fileName] else { continue }
            let url = store.url(for: photo)
            guard let data = try? Data(contentsOf: url) else { continue }
            // A raw byte copy — no decode, no re-encode.
            items.append(ExportedArchive(data: data, suggestedName: entry.name))
        }
        if options.includeCaptions {
            let document = CaptionDocument.build(plan: plan, options: options, exportedAt: Date())
            items.append(
                ExportedArchive(
                    data: Data(document.utf8),
                    suggestedName: options.captionFormat.fileName
                )
            )
        }
        return items
    }

    /// The document on its own, for a user who already has the images somewhere else.
    static func captionsOnly(
        photos: [Photo],
        scope: ExportScope,
        options: ExportOptions
    ) throws -> ExportedArchive {
        let plan = ExportNaming.plan(photos: photos.map(\.record), scope: scope, options: options)
        guard !plan.isEmpty else { throw ExportFailure.nothingToExport }
        let document = CaptionDocument.build(plan: plan, options: options, exportedAt: Date())
        return ExportedArchive(
            data: Data(document.utf8),
            suggestedName: options.captionFormat.fileName
        )
    }
}
