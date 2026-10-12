import XCTest
@testable import PhotoLogKit

/// The ordering, naming and archive contract.
///
/// These are the requirements that cannot be checked by looking at a screen: they are about what
/// ends up inside the generated file. They run on `swift test` — no simulator, no signing, no
/// Xcode project — which is what makes them verifiable on a macOS CI runner even though the app
/// itself cannot be built anywhere else in this repository.
final class ExportTests: XCTestCase {

    // MARK: - fixtures

    private func photo(
        _ id: Int64,
        caption: String = "",
        originalName: String? = nil,
        mimeType: String = "image/jpeg",
        addedAt: TimeInterval? = nil,
        sortIndex: Int64? = nil,
        fileName: String? = nil
    ) -> PhotoRecord {
        let base = Date(timeIntervalSince1970: 1_760_000_000)
        return PhotoRecord(
            id: id,
            caption: caption,
            fileName: fileName ?? "g_\(id).jpg",
            originalName: originalName ?? String(format: "IMG_%04d.jpg", Int(id)),
            mimeType: mimeType,
            width: 4000,
            height: 3000,
            sizeBytes: 1024 * id,
            sha256: "sha\(id)",
            capturedAt: base.addingTimeInterval(TimeInterval(id)),
            addedAt: addedAt.map { Date(timeIntervalSince1970: $0) } ?? base.addingTimeInterval(TimeInterval(id)),
            source: "GALLERY",
            sortIndex: sortIndex ?? id
        )
    }

    private func options(_ overrides: (inout ExportOptions) -> Void = { _ in }) -> ExportOptions {
        var value = ExportOptions()
        overrides(&value)
        return value
    }

    // MARK: - order and prefix

    func testPlanPreservesLibraryOrderAndNumbersFiles() {
        let plan = ExportNaming.plan(
            photos: [photo(1), photo(2), photo(3)],
            scope: .all,
            options: options()
        )
        XCTAssertEqual(
            plan.map(\.name),
            ["001_IMG_0001.jpg", "002_IMG_0002.jpg", "003_IMG_0003.jpg"]
        )
        XCTAssertEqual(plan.map(\.photo.id), [1, 2, 3])
    }

    func testNumericPrefixCanBeOmitted() {
        let plan = ExportNaming.plan(
            photos: [photo(1), photo(2)],
            scope: .all,
            options: options { $0.numbered = false }
        )
        XCTAssertEqual(plan.map(\.name), ["IMG_0001.jpg", "IMG_0002.jpg"])
    }

    func testRecentScopeTakesNewestButExportsInLibraryOrder() {
        let library = (1...25).map { photo(Int64($0), addedAt: TimeInterval($0), sortIndex: Int64($0)) }
        let plan = ExportNaming.plan(photos: library, scope: .recent, options: options())

        XCTAssertEqual(plan.count, 20)
        XCTAssertEqual(plan.map(\.photo.id), Array(6...25).map(Int64.init))
        XCTAssertEqual(plan.map(\.photo.sortIndex), plan.map(\.photo.sortIndex).sorted())
    }

    func testCaptionOnlyScopeKeepsAnnotatedPhotos() {
        let plan = ExportNaming.plan(
            photos: [photo(1, caption: "清晨的雾"), photo(2), photo(3, caption: "傍晚的云")],
            scope: .withCaption,
            options: options()
        )
        XCTAssertEqual(plan.map(\.photo.id), [1, 3])
    }

    // MARK: - caption becomes the file name

    func testChineseCaptionBecomesFileName() {
        let plan = ExportNaming.plan(
            photos: [photo(1, caption: "清晨的雾"), photo(2, caption: "傍晚的云")],
            scope: .all,
            options: options()
        )
        XCTAssertEqual(plan.map(\.name), ["001_清晨的雾.jpg", "002_傍晚的云.jpg"])
    }

    func testFullWidthPunctuationKeptWhileAsciiIllegalCharactersAreReplaced() {
        let plan = ExportNaming.plan(
            photos: [photo(1, caption: "阳台：第 3 盆｜晴")],
            scope: .all,
            options: options { $0.numbered = false }
        )
        XCTAssertEqual(plan[0].name, "阳台：第 3 盆｜晴.jpg")
    }

    func testAsciiPathSeparatorCannotCreateDirectory() {
        let plan = ExportNaming.plan(
            photos: [photo(1, caption: "旅行/第一天")],
            scope: .all,
            options: options { $0.numbered = false }
        )
        XCTAssertEqual(plan[0].name, "旅行_第一天.jpg")
    }

    func testMultiLineCaptionFlattened() {
        let plan = ExportNaming.plan(
            photos: [photo(1, caption: "第一行\n第二行\t第三行")],
            scope: .all,
            options: options { $0.numbered = false }
        )
        XCTAssertEqual(plan[0].name, "第一行_第二行_第三行.jpg")
    }

    func testLongChineseCaptionTruncated() {
        let plan = ExportNaming.plan(
            photos: [photo(1, caption: String(repeating: "字", count: 120))],
            scope: .all,
            options: options { $0.numbered = false }
        )
        XCTAssertEqual(plan[0].name, String(repeating: "字", count: 60) + ".jpg")
    }

    /// Swift truncates by `Character`, which is an extended grapheme cluster — stricter than the
    /// UTF-16 units the Android build counts and the code points the HarmonyOS build counts. An
    /// emoji, or an emoji built from a ZWJ sequence, therefore cannot be cut in half here.
    func testTruncationKeepsEmojiWhole() {
        let caption = String(repeating: "字", count: 59) + "🌅"
        let plan = ExportNaming.plan(
            photos: [photo(1, caption: caption)],
            scope: .all,
            options: options { $0.numbered = false }
        )
        XCTAssertEqual(plan[0].name, caption + ".jpg")

        let zwj = String(repeating: "字", count: 59) + "👨‍👩‍👧"
        let zwjPlan = ExportNaming.plan(
            photos: [photo(1, caption: zwj)],
            scope: .all,
            options: options { $0.numbered = false }
        )
        XCTAssertEqual(zwjPlan[0].name, zwj + ".jpg", "a ZWJ sequence must not be split either")
    }

    func testBlankCaptionFallsBackToOriginalName() {
        let plan = ExportNaming.plan(
            photos: [photo(1, caption: "   ", originalName: "IMG_0001.jpg")],
            scope: .all,
            options: options { $0.numbered = false }
        )
        XCTAssertEqual(plan[0].name, "IMG_0001.jpg")
    }

    func testPhotoWithNoOriginalNameFallsBackToGeneratedName() {
        let plan = ExportNaming.plan(
            photos: [photo(1, originalName: "", fileName: "g_20261012_093155_456.jpg")],
            scope: .all,
            options: options { $0.numbered = false }
        )
        XCTAssertEqual(plan[0].name, "g_20261012_093155_456.jpg")
    }

    func testDuplicateCaptionsGetDistinctNames() {
        let plan = ExportNaming.plan(
            photos: [photo(1, caption: "随手拍"), photo(2, caption: "随手拍")],
            scope: .all,
            options: options { $0.numbered = false }
        )
        XCTAssertEqual(plan.map(\.name), ["随手拍.jpg", "随手拍_2.jpg"])
    }

    func testNamingCanFallBackToOriginalName() {
        let plan = ExportNaming.plan(
            photos: [photo(1, caption: "清晨的雾", originalName: "IMG_0001.jpg")],
            scope: .all,
            options: options {
                $0.numbered = false
                $0.useCaptionAsName = false
            }
        )
        XCTAssertEqual(plan[0].name, "IMG_0001.jpg")
    }

    func testWindowsDeviceNameIsEscaped() {
        let plan = ExportNaming.plan(
            photos: [photo(1, caption: "CON")],
            scope: .all,
            options: options { $0.numbered = false }
        )
        XCTAssertEqual(plan[0].name, "_CON.jpg")
    }

    func testLosslessKeepsExtensionAndLossyForcesJpeg() {
        let png = [photo(1, originalName: "shot.png", mimeType: "image/png")]
        let lossless = ExportNaming.plan(photos: png, scope: .all, options: options())
        let lossy = ExportNaming.plan(photos: png, scope: .all, options: options { $0.lossless = false })

        XCTAssertEqual(lossless[0].name, "001_shot.png")
        XCTAssertEqual(lossless[0].mimeType, "image/png")
        XCTAssertEqual(lossy[0].name, "001_shot.jpg")
        XCTAssertEqual(lossy[0].mimeType, "image/jpeg")
    }

    func testExtensionComesFromBytesNotCaption() {
        let plan = ExportNaming.plan(
            photos: [photo(1, caption: "截图.png", mimeType: "image/jpeg")],
            scope: .all,
            options: options { $0.numbered = false }
        )
        XCTAssertEqual(plan[0].name, "截图.png.jpg")
        XCTAssertEqual(plan[0].mimeType, "image/jpeg")
    }

    // MARK: - caption document

    func testMarkdownPutsEachCaptionUnderItsOwnImageInOrder() {
        let plan = ExportNaming.plan(
            photos: [photo(1, caption: "第一张：清晨的雾"), photo(2, caption: "第二张：傍晚的云")],
            scope: .all,
            options: options()
        )
        let document = CaptionDocument.build(plan: plan, options: options(), exportedAt: Date())

        let first = document.range(of: "![001](images/\(plan[0].name))")
        let firstCaption = document.range(of: "第一张：清晨的雾")
        let second = document.range(of: "![002](images/\(plan[1].name))")
        let secondCaption = document.range(of: "第二张：傍晚的云")

        XCTAssertNotNil(first)
        XCTAssertNotNil(firstCaption)
        XCTAssertNotNil(second)
        XCTAssertNotNil(secondCaption)
        if let first, let firstCaption, let second, let secondCaption {
            XCTAssertLessThan(first.lowerBound, firstCaption.lowerBound)
            XCTAssertLessThan(firstCaption.lowerBound, second.lowerBound)
            XCTAssertLessThan(second.lowerBound, secondCaption.lowerBound)
        }
    }

    func testMarkdownImagePathMatchesExportedName() {
        let plan = ExportNaming.plan(
            photos: [photo(7, caption: "清晨的雾")],
            scope: .all,
            options: options()
        )
        XCTAssertEqual(plan[0].name, "001_清晨的雾.jpg")
        let document = CaptionDocument.build(plan: plan, options: options(), exportedAt: Date())
        XCTAssertTrue(document.contains("![001](images/001_清晨的雾.jpg)"))
    }

    func testMissingCaptionIsMarked() {
        let plan = ExportNaming.plan(photos: [photo(1)], scope: .all, options: options())
        let markdown = CaptionDocument.build(plan: plan, options: options(), exportedAt: Date())
        let text = CaptionDocument.build(
            plan: plan,
            options: options { $0.captionFormat = .text },
            exportedAt: Date()
        )
        XCTAssertTrue(markdown.contains("（无说明）"))
        XCTAssertTrue(text.contains("（无说明）"))
    }

    func testPlainTextDocumentStartsWithUtf8Bom() {
        let plan = ExportNaming.plan(photos: [photo(1, caption: "清晨的雾")], scope: .all, options: options())
        let bytes = Array(
            CaptionDocument.build(
                plan: plan,
                options: options { $0.captionFormat = .text },
                exportedAt: Date()
            ).utf8
        )
        XCTAssertEqual(Array(bytes.prefix(3)), [0xEF, 0xBB, 0xBF])
    }

    func testMarkdownAndHtmlCarryNoBom() {
        let plan = ExportNaming.plan(photos: [photo(1, caption: "清晨的雾")], scope: .all, options: options())
        let markdown = CaptionDocument.build(plan: plan, options: options(), exportedAt: Date())
        let html = CaptionDocument.build(
            plan: plan,
            options: options { $0.captionFormat = .html },
            exportedAt: Date()
        )
        XCTAssertFalse(markdown.hasPrefix("\u{FEFF}"))
        XCTAssertTrue(markdown.hasPrefix("#"))
        XCTAssertFalse(html.hasPrefix("\u{FEFF}"))
        XCTAssertTrue(html.hasPrefix("<!DOCTYPE html>"))
        XCTAssertTrue(html.contains("<meta charset=\"utf-8\">"))
    }

    func testHtmlEscapesTextThatWouldBreakThePage() {
        let plan = ExportNaming.plan(
            photos: [photo(1, caption: "<script>alert(1)</script> & \"q\"")],
            scope: .all,
            options: options()
        )
        let html = CaptionDocument.build(
            plan: plan,
            options: options { $0.captionFormat = .html },
            exportedAt: Date()
        )
        XCTAssertTrue(html.contains("&lt;script&gt;alert(1)&lt;/script&gt;"))
        XCTAssertTrue(html.contains("&amp;"))
        XCTAssertTrue(html.contains("&quot;q&quot;"))
        XCTAssertFalse(html.contains("<script>"))
    }

    func testDocumentRecordsExportMode() {
        let plan = ExportNaming.plan(photos: [photo(1)], scope: .all, options: options())
        let lossless = CaptionDocument.build(plan: plan, options: options(), exportedAt: Date())
        let lossy = CaptionDocument.build(
            plan: plan,
            options: options {
                $0.lossless = false
                $0.jpegQuality = 0.9
            },
            exportedAt: Date()
        )
        XCTAssertTrue(lossless.contains("无损"))
        XCTAssertTrue(lossy.contains("质量 90"))
    }

    // MARK: - archive bytes

    func testArchiveHeaderFieldsAreCorrect() throws {
        let imageBytes = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77])
        let plan = ExportNaming.plan(photos: [photo(1, caption: "清晨的雾")], scope: .all, options: options())
        let entryName = "images/\(plan[0].name)"

        let archive = ZipWriter.archive(
            entries: [ZipWriter.Entry(name: entryName, data: imageBytes)],
            modifiedAt: Date()
        )

        XCTAssertEqual(readUInt32(archive, 0), 0x0403_4B50, "local file header signature")
        XCTAssertEqual(readUInt16(archive, 8), 0, "compression method must be STORE")

        let flags = readUInt16(archive, 6)
        XCTAssertEqual(flags & 0x0800, 0x0800, "EFS (utf-8 name) flag must be set")
        XCTAssertEqual(flags & 0x0008, 0, "no data descriptor flag")

        XCTAssertEqual(readUInt32(archive, 14), ZipWriter.Crc32.checksum(imageBytes))
        XCTAssertEqual(Int(readUInt32(archive, 18)), imageBytes.count)
        XCTAssertEqual(Int(readUInt32(archive, 22)), imageBytes.count)

        let nameLength = Int(readUInt16(archive, 26))
        XCTAssertEqual(nameLength, entryName.utf8.count)
        XCTAssertEqual(
            String(decoding: archive[30..<(30 + nameLength)], as: UTF8.self),
            entryName
        )

        let dataStart = 30 + nameLength
        XCTAssertEqual(archive[dataStart..<(dataStart + imageBytes.count)], imageBytes)

        let eocd = archive.count - 22
        XCTAssertEqual(readUInt32(archive, eocd), 0x0605_4B50, "end of central directory")
        XCTAssertEqual(readUInt16(archive, eocd + 10), 1, "entry count")
        XCTAssertEqual(
            Int(readUInt32(archive, eocd + 16)),
            dataStart + imageBytes.count,
            "central directory offset"
        )
    }

    func testEmptyArchiveIsAValidZip() {
        let archive = ZipWriter.archive(entries: [], modifiedAt: Date())
        XCTAssertEqual(archive.count, 22)
        XCTAssertEqual(readUInt32(archive, 0), 0x0605_4B50)
        XCTAssertEqual(readUInt16(archive, 10), 0)
    }

    /// The test that matters most: hand the archive to the system's own extractor and read it
    /// back.
    ///
    /// **`ditto`, not `unzip`.** macOS ships an old Info-ZIP 6.00 at `/usr/bin/unzip` that does not
    /// honour the UTF-8 name flag; it re-encodes the name through the current locale and produces
    /// `001_���ֿ������.jpg`. That is a defect in that particular binary, not in the archive — the
    /// same bytes extract correctly under Windows' `Expand-Archive` and under `bsdtar`. Apple's
    /// own `ditto` handles the flag, and it is what Finder's Archive Utility is built on, so it is
    /// the extractor a real user on macOS actually goes through.
    ///
    /// `ditto` also fails on a corrupt entry, so a wrong CRC surfaces here rather than passing
    /// silently.
    func testSystemExtractorReadsChineseEntryNamesIntact() throws {
        let imageBytes = Data((0..<2048).map { UInt8($0 % 251) })
        let plan = ExportNaming.plan(photos: [photo(1, caption: "清晨的雾")], scope: .all, options: options())
        let imageEntry = "images/\(plan[0].name)"
        let captions = CaptionDocument.build(plan: plan, options: options(), exportedAt: Date())

        let archive = ZipWriter.archive(
            entries: [
                ZipWriter.Entry(name: imageEntry, data: imageBytes),
                ZipWriter.Entry(name: "captions.md", data: Data(captions.utf8)),
            ],
            modifiedAt: Date()
        )

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("photolog-verify-\(UUID().uuidString)")
        let extractDir = root.appendingPathComponent("extracted")
        try FileManager.default.createDirectory(at: extractDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let archiveURL = root.appendingPathComponent("export.zip")
        try archive.write(to: archiveURL)

        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-x", "-k", archiveURL.path, extractDir.path]
        let pipe = Pipe()
        ditto.standardError = pipe
        try ditto.run()
        ditto.waitUntilExit()

        let stderr = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        XCTAssertEqual(ditto.terminationStatus, 0, "ditto failed: \(stderr)")

        let imagePath = extractDir.appendingPathComponent(imageEntry)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: imagePath.path),
            "the chinese-named entry did not survive extraction"
        )
        XCTAssertEqual(try Data(contentsOf: imagePath), imageBytes, "lossless must be byte-for-byte")

        let captionsPath = extractDir.appendingPathComponent("captions.md")
        XCTAssertTrue(FileManager.default.fileExists(atPath: captionsPath.path))
        let readBack = try String(contentsOf: captionsPath, encoding: .utf8)
        XCTAssertTrue(readBack.contains("清晨的雾"))
        XCTAssertTrue(readBack.contains(imageEntry))
    }

    // MARK: - helpers

    private func readUInt16(_ data: Data, _ offset: Int) -> UInt16 {
        UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private func readUInt32(_ data: Data, _ offset: Int) -> UInt32 {
        UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }
}
