import Foundation

/// How the caption file is written.
public enum CaptionFormat: String, CaseIterable, Sendable {
    case markdown
    case html
    case text

    public var label: String {
        switch self {
        case .markdown: return "Markdown"
        case .html: return "HTML 网页"
        case .text: return "纯文本"
        }
    }

    public var fileName: String {
        switch self {
        case .markdown: return "captions.md"
        case .html: return "captions.html"
        case .text: return "captions.txt"
        }
    }

    public var mimeType: String {
        switch self {
        case .markdown: return "text/markdown"
        case .html: return "text/html"
        case .text: return "text/plain"
        }
    }
}

/// Which photos go into an export.
public enum ExportScope: String, CaseIterable, Sendable {
    case all
    case withCaption
    case recent

    public var label: String {
        switch self {
        case .all: return "全部照片"
        case .withCaption: return "仅有文字说明"
        case .recent: return "最近 20 张"
        }
    }
}

/// The export knobs.
///
/// `lossless` is the one that matters: when it is true the stored original is copied byte for
/// byte and every other field is ignored.
public struct ExportOptions: Sendable {
    public var lossless: Bool
    public var jpegQuality: Double
    public var maxLongEdge: Int
    public var includeCaptions: Bool
    public var captionFormat: CaptionFormat
    public var numbered: Bool
    public var useCaptionAsName: Bool

    public init(
        lossless: Bool = true,
        jpegQuality: Double = 0.95,
        maxLongEdge: Int = 4096,
        includeCaptions: Bool = true,
        captionFormat: CaptionFormat = .markdown,
        numbered: Bool = true,
        useCaptionAsName: Bool = true
    ) {
        self.lossless = lossless
        self.jpegQuality = jpegQuality
        self.maxLongEdge = maxLongEdge
        self.includeCaptions = includeCaptions
        self.captionFormat = captionFormat
        self.numbered = numbered
        self.useCaptionAsName = useCaptionAsName
    }
}

/// One library row.
///
/// Structurally the `PhotoRecord` of the other two builds, so a library exported on one platform
/// lines up field for field with the others.
public struct PhotoRecord: Identifiable, Hashable, Sendable {
    public var id: Int64
    public var caption: String
    public var fileName: String
    public var originalName: String
    public var mimeType: String
    public var width: Int
    public var height: Int
    public var sizeBytes: Int64
    public var sha256: String
    public var capturedAt: Date
    public var addedAt: Date
    public var source: String
    public var sortIndex: Int64

    public init(
        id: Int64 = 0,
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
}

/// One photo's place in an export.
public struct ExportEntry: Sendable {
    public let photo: PhotoRecord
    public let index: Int
    public let name: String
    public let mimeType: String

    public var archivePath: String { "\(ExportNaming.imagesDir)/\(name)" }
}

/// The extension to store or export under. Unknown types keep an honest `bin`.
public func extensionForMime(_ mime: String) -> String {
    switch mime.trimmingCharacters(in: .whitespaces).lowercased() {
    case "image/jpeg", "image/jpg", "image/pjpeg": return "jpg"
    case "image/png": return "png"
    case "image/webp": return "webp"
    case "image/gif": return "gif"
    case "image/bmp", "image/x-ms-bmp": return "bmp"
    case "image/heic", "image/heif", "image/heic-sequence": return "heic"
    case "image/avif": return "avif"
    case "image/tiff": return "tiff"
    default: return "bin"
    }
}

/// The order and the file names of an export.
///
/// Naming rule in one line: **the image is named after the caption under it** when the photo has
/// one, otherwise after the source file name. `photos` must arrive already in the user's order
/// (`sortIndex` ascending) — preserving that order is the point of the feature.
public enum ExportNaming {
    public static let imagesDir = "images"
    static let fallbackName = "photo"
    static let maxNameCharacters = 60

    public static func plan(
        photos: [PhotoRecord],
        scope: ExportScope,
        options: ExportOptions
    ) -> [ExportEntry] {
        let ordered: [PhotoRecord]
        switch scope {
        case .all:
            ordered = photos
        case .withCaption:
            ordered = photos.filter { !$0.caption.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        case .recent:
            let newest = photos.sorted { $0.addedAt > $1.addedAt }.prefix(20)
            ordered = newest.sorted { $0.sortIndex < $1.sortIndex }
        }

        var used = Set<String>()
        var plan: [ExportEntry] = []
        for (position, photo) in ordered.enumerated() {
            let ext = options.lossless ? extensionForMime(photo.mimeType) : "jpg"
            let base = baseName(photo, options: options)
            let prefix = options.numbered ? padIndex(position + 1) : ""
            var name = "\(prefix)\(base).\(ext)"
            var suffix = 2
            // Case-insensitive: an archive holding both `Photo.JPG` and `photo.jpg` collides on
            // extraction on Windows and macOS, where the filesystem is case-insensitive.
            while used.contains(name.lowercased()) {
                name = "\(prefix)\(base)_\(suffix).\(ext)"
                suffix += 1
            }
            used.insert(name.lowercased())
            plan.append(
                ExportEntry(
                    photo: photo,
                    index: position + 1,
                    name: name,
                    mimeType: options.lossless ? photo.mimeType : "image/jpeg"
                )
            )
        }
        return plan
    }

    /// A file name for the single-photo export, without an order prefix.
    public static func suggestedName(_ photo: PhotoRecord, options: ExportOptions) -> String {
        "\(baseName(photo, options: options)).\(extensionForMime(photo.mimeType))"
    }

    /// What the file is called, before the order prefix and the extension.
    ///
    /// The caption wins when there is one — that is the feature. Everything else is a fallback
    /// chain: the source app's own name, then the name this app generated, then the literal
    /// `photo` if even that sanitises away to nothing.
    static func baseName(_ photo: PhotoRecord, options: ExportOptions) -> String {
        if options.useCaptionAsName {
            let caption = photo.caption.trimmingCharacters(in: .whitespacesAndNewlines)
            if !caption.isEmpty {
                return sanitize(caption)
            }
        }
        let original = stripExtension(photo.originalName)
        if !original.isEmpty {
            return sanitize(original)
        }
        return sanitize(stripExtension(photo.fileName))
    }

    /// Turns arbitrary user text into a name that survives every filesystem this archive may land
    /// on.
    ///
    /// Chinese needs no special handling and gets none: CJK ideographs, full-width punctuation
    /// (`：`, `？`, `｜`) and emoji are all legal in a file name on iOS, Windows, macOS and Linux,
    /// so the filter only removes what is actually illegal. Notably it does **not** touch `：` —
    /// the ASCII `:` is illegal on Windows, the full-width one is a different character and is
    /// fine, and rewriting it would mangle a Chinese sentence for nothing.
    public static func sanitize(_ raw: String) -> String {
        var filtered = String()
        filtered.reserveCapacity(raw.count)
        for character in raw {
            filtered.append(isUnsafe(character) ? "_" : character)
        }

        var out = filtered
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
        out = trim(out, of: " ")
        out = trim(out, of: ".")
        out = String(out.prefix(maxNameCharacters))
        out = trim(out, of: " ")
        out = trim(out, of: ".")
        if out.isEmpty {
            out = fallbackName
        }
        if windowsReserved.contains(out.uppercased()) {
            out = "_" + out
        }
        return out
    }

    static func padIndex(_ index: Int) -> String {
        index < 10 ? "00\(index)_" : (index < 100 ? "0\(index)_" : "\(index)_")
    }

    static func stripExtension(_ name: String) -> String {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return name }
        return String(name[name.startIndex..<dot])
    }

    static func trim(_ value: String, of character: Character) -> String {
        var start = value.startIndex
        var end = value.endIndex
        while start < end, value[start] == character { start = value.index(after: start) }
        while end > start, value[value.index(before: end)] == character { end = value.index(before: end) }
        return String(value[start..<end])
    }

    /// Characters illegal in a file name on at least one target platform.
    ///
    /// The control-character test covers the newlines and tabs a multi-line caption contains,
    /// which are illegal everywhere rather than merely awkward.
    static func isUnsafe(_ character: Character) -> Bool {
        if let ascii = character.asciiValue {
            if ascii < 0x20 || ascii == 0x7F { return true }
        }
        return "\\/:*?\"<>|".contains(character)
    }

    /// Device names Windows resolves to hardware rather than to a file, so a caption of `CON`
    /// would produce an image nobody can open there. Prefixing keeps the caption recognisable
    /// instead of replacing it.
    static let windowsReserved: Set<String> = [
        "CON", "PRN", "AUX", "NUL",
        "COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7", "COM8", "COM9",
        "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9",
    ]
}

/// The "图片 + 图下文字说明" document.
///
/// The order of the entries in the file is the order of the photos, and each caption sits
/// directly under its image — which is the requirement, and also the only arrangement that
/// survives being copied into a chat or a document.
public enum CaptionDocument {
    static let noCaption = "（无说明）"
    /// U+FEFF, written out as EF BB BF when the string is encoded as UTF-8.
    static let bom = "\u{FEFF}"

    public static func build(plan: [ExportEntry], options: ExportOptions, exportedAt: Date) -> String {
        switch options.captionFormat {
        case .markdown: return markdown(plan, options: options, exportedAt: exportedAt)
        case .html: return html(plan, options: options, exportedAt: exportedAt)
        case .text: return text(plan, options: options, exportedAt: exportedAt)
        }
    }

    static func metadata(
        plan: [ExportEntry],
        options: ExportOptions,
        exportedAt: Date
    ) -> [(String, String)] {
        let annotated = plan.filter {
            !$0.photo.caption.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }.count
        let mode: String
        if options.lossless {
            mode = "无损（原样复制，未重新编码，EXIF 保留）"
        } else {
            let edge = options.maxLongEdge > 0 ? "，最长边 \(options.maxLongEdge)px" : "，原始尺寸"
            mode = "重新编码 JPEG（质量 \(Int(options.jpegQuality * 100))\(edge)）"
        }
        return [
            ("导出时间", formatStamp(exportedAt)),
            ("照片数量", "\(plan.count)"),
            ("图片目录", "\(ExportNaming.imagesDir)/"),
            ("图片模式", mode),
            ("已写说明", "\(annotated) / \(plan.count)"),
        ]
    }

    static func markdown(plan: [ExportEntry], options: ExportOptions, exportedAt: Date) -> String {
        var out = "# 图志导出\n\n"
        for (key, value) in metadata(plan: plan, options: options, exportedAt: exportedAt) {
            out += "- \(key)：\(value)\n"
        }
        for entry in plan {
            let label = indexLabel(entry.index)
            out += "\n---\n\n"
            out += "## \(label) · \(formatStamp(entry.photo.capturedAt))\n\n"
            out += "![\(label)](\(ExportNaming.imagesDir)/\(entry.name))\n\n"
            out += "\(entry.photo.caption.isEmpty ? noCaption : entry.photo.caption)\n"
        }
        return out
    }

    static func html(plan: [ExportEntry], options: ExportOptions, exportedAt: Date) -> String {
        var out = "<!DOCTYPE html>\n<html lang=\"zh-CN\">\n<head>\n<meta charset=\"utf-8\">\n"
        out += "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n"
        out += "<title>图志导出</title>\n<style>\n"
        out += ":root{color-scheme:light dark}\n"
        out += "body{margin:0;padding:24px;background:#f8f9fc;color:#191c20;line-height:1.7;"
        out += "font-family:-apple-system,\"PingFang SC\",system-ui,sans-serif}\n"
        out += "h1{font-size:22px;margin:0 0 12px}\n"
        out += ".meta{color:#43474e;font-size:14px;margin:0 0 28px}\n"
        out += "figure{margin:0 0 32px;background:#fff;border-radius:12px;overflow:hidden;"
        out += "box-shadow:0 1px 3px rgba(0,0,0,.12)}\n"
        out += "figure img{display:block;width:100%;height:auto;background:#e0e2ec}\n"
        out += "figcaption{padding:14px 16px;font-size:15px}\n"
        out += "figcaption .idx{display:inline-block;min-width:2.6em;color:#1d4e89;font-weight:600}\n"
        out += "@media (prefers-color-scheme:dark){body{background:#111318;color:#e2e2e6}"
        out += ".meta{color:#c3c6cf}figure{background:#1c1f24;box-shadow:none}"
        out += "figure img{background:#43474e}figcaption .idx{color:#a6c8ff}}\n"
        out += "</style>\n</head>\n<body>\n<h1>图志导出</h1>\n<p class=\"meta\">\n"
        for (key, value) in metadata(plan: plan, options: options, exportedAt: exportedAt) {
            out += "\(escape(key))：\(escape(value))<br>\n"
        }
        out += "</p>\n"
        for entry in plan {
            let label = indexLabel(entry.index)
            let caption = entry.photo.caption.isEmpty ? noCaption : entry.photo.caption
            let source = escape("\(ExportNaming.imagesDir)/\(entry.name)")
            out += "<figure>\n"
            out += "<img src=\"\(source)\" alt=\"\(label)\" loading=\"lazy\">\n"
            out += "<figcaption><span class=\"idx\">\(label)</span>\(escape(caption))</figcaption>\n"
            out += "</figure>\n"
        }
        out += "</body>\n</html>\n"
        return out
    }

    static func text(plan: [ExportEntry], options: ExportOptions, exportedAt: Date) -> String {
        // The BOM is the only way a .txt can declare its encoding; without it a Chinese caption
        // opened in Notepad or Excel is mojibake.
        var out = bom + "图志导出\n"
        for (key, value) in metadata(plan: plan, options: options, exportedAt: exportedAt) {
            out += "\(key)：\(value)\n"
        }
        out += "\n# 序号\t图片路径\t文字说明\n"
        for entry in plan {
            let caption = entry.photo.caption
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\t", with: " ")
            out += "\(indexLabel(entry.index))\t\(ExportNaming.imagesDir)/\(entry.name)\t"
            out += "\(caption.isEmpty ? noCaption : caption)\n"
        }
        return out
    }

    static func indexLabel(_ index: Int) -> String {
        index < 10 ? "00\(index)" : (index < 100 ? "0\(index)" : "\(index)")
    }

    static func formatStamp(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.current
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(
            format: "%04d-%02d-%02d %02d:%02d:%02d",
            parts.year ?? 0, parts.month ?? 0, parts.day ?? 0,
            parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0
        )
    }

    static func escape(_ raw: String) -> String {
        raw
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
