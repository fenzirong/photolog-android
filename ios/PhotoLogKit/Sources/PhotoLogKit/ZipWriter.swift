import Foundation

/// A minimal ZIP writer.
///
/// ## Why not a library
///
/// The only thing that matters about an archive of photos whose file names are Chinese captions is
/// one bit: the general purpose flag that declares the names are UTF-8. Without it Windows
/// extractors read the bytes through the system code page and every Chinese name is mojibake.
/// `Foundation` has no ZIP API at all, `AppleArchive` writes Apple's own format rather than ZIP,
/// and a third-party dependency would be a large amount of code to gain control of one bit — so
/// the archive is written here, where that bit is reachable.
///
/// ## Why STORE and not DEFLATE
///
/// Every entry is a photo, and a JPEG/PNG/HEIC is already compressed: DEFLATE over it costs CPU
/// and saves approximately nothing. Method 0 (STORE) is therefore not a shortcut but the right
/// choice for this archive.
///
/// ## Layout produced
///
/// ```
/// [local header][name][data]  ×N
/// [central directory header][name] ×N
/// [end of central directory]
/// ```
public enum ZipWriter {
    /// Table-driven CRC-32 (the reflected polynomial ZIP uses, 0xEDB88320).
    public enum Crc32 {
        private static let table: [UInt32] = (0..<256).map { n -> UInt32 in
            var c = UInt32(n)
            for _ in 0..<8 {
                c = (c & 1) != 0 ? (0xEDB8_8320 ^ (c >> 1)) : (c >> 1)
            }
            return c
        }

        public static func checksum(_ data: Data) -> UInt32 {
            var c: UInt32 = 0xFFFF_FFFF
            for byte in data {
                c = table[Int((c ^ UInt32(byte)) & 0xFF)] ^ (c >> 8)
            }
            return c ^ 0xFFFF_FFFF
        }
    }

    /// One entry's bytes.
    ///
    /// `bytes` may be read more than once: the writer makes a first pass to compute the CRC and a
    /// second to emit. The closure exists so a caller can stream a large file off disk instead of
    /// holding every photo in memory at once.
    public struct Entry {
        public let name: String
        public let size: Int
        public let bytes: () -> Data

        public init(name: String, size: Int, bytes: @escaping () -> Data) {
            self.name = name
            self.size = size
            self.bytes = bytes
        }

        /// Convenience for entries that already exist in memory.
        public init(name: String, data: Data) {
            self.name = name
            self.size = data.count
            self.bytes = { data }
        }
    }

    /// Builds the archive.
    ///
    /// Entry order is preserved exactly — that order *is* the export order, which is the point of
    /// the feature.
    public static func archive(entries: [Entry], modifiedAt: Date = Date()) -> Data {
        let (dosTime, dosDate) = dosStamp(modifiedAt)

        // Pass 1: CRC of every entry, because the local header precedes the data and must already
        // carry it. The alternative — a data descriptor with flag bit 3 — is a less universally
        // supported combination, and reading a file twice costs nothing next to being unable to
        // open the result.
        var crcs: [UInt32] = []
        var payloads: [Data] = []
        crcs.reserveCapacity(entries.count)
        payloads.reserveCapacity(entries.count)
        for entry in entries {
            let data = entry.bytes()
            payloads.append(data)
            crcs.append(Crc32.checksum(data))
        }

        var archive = Data()
        var offsets: [UInt32] = []
        offsets.reserveCapacity(entries.count)

        // Pass 2: local headers and data.
        for (index, entry) in entries.enumerated() {
            offsets.append(UInt32(archive.count))
            let nameBytes = Data(entry.name.utf8)
            let payload = payloads[index]

            var header = Data()
            header.appendUInt32(0x0403_4B50)          // local file header signature
            header.appendUInt16(20)                    // version needed to extract
            // Bit 11 (EFS) declares the name is UTF-8. Set unconditionally: an ASCII name is valid
            // UTF-8, and the alternative is a per-name decision that is wrong exactly once.
            header.appendUInt16(0x0800)
            header.appendUInt16(0)                     // method 0 = STORE
            header.appendUInt16(dosTime)
            header.appendUInt16(dosDate)
            header.appendUInt32(crcs[index])
            header.appendUInt32(UInt32(payload.count))
            header.appendUInt32(UInt32(payload.count))
            header.appendUInt16(UInt16(nameBytes.count))
            header.appendUInt16(0)                     // extra field length
            archive.append(header)
            archive.append(nameBytes)
            archive.append(payload)
        }

        // Central directory.
        let directoryStart = UInt32(archive.count)
        for (index, entry) in entries.enumerated() {
            let nameBytes = Data(entry.name.utf8)
            let payload = payloads[index]

            var record = Data()
            record.appendUInt32(0x0201_4B50)          // central directory header signature
            record.appendUInt16(20)                    // version made by
            record.appendUInt16(20)                    // version needed to extract
            record.appendUInt16(0x0800)
            record.appendUInt16(0)
            record.appendUInt16(dosTime)
            record.appendUInt16(dosDate)
            record.appendUInt32(crcs[index])
            record.appendUInt32(UInt32(payload.count))
            record.appendUInt32(UInt32(payload.count))
            record.appendUInt16(UInt16(nameBytes.count))
            record.appendUInt16(0)                     // extra field length
            record.appendUInt16(0)                     // file comment length
            record.appendUInt16(0)                     // disk number start
            record.appendUInt16(0)                     // internal attributes
            record.appendUInt32(0)                     // external attributes
            record.appendUInt32(offsets[index])
            record.append(nameBytes)
            archive.append(record)
        }
        let directorySize = UInt32(archive.count) - directoryStart

        // End of central directory.
        var end = Data()
        end.appendUInt32(0x0605_4B50)
        end.appendUInt16(0)                            // this disk
        end.appendUInt16(0)                            // disk with central directory
        end.appendUInt16(UInt16(entries.count))
        end.appendUInt16(UInt16(entries.count))
        end.appendUInt32(directorySize)
        end.appendUInt32(directoryStart)
        end.appendUInt16(0)                            // comment length
        archive.append(end)

        return archive
    }

    /// MS-DOS date and time, which is what the ZIP format stores.
    ///
    /// Seconds have two-second resolution by design of the format; the odd second is dropped
    /// rather than rounded, which is what every other writer does. Years before 1980 are clamped
    /// rather than wrapping to a nonsensical future date.
    static func dosStamp(_ date: Date) -> (UInt16, UInt16) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.current
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let year = parts.year ?? 1980
        let y = year < 1980 ? 0 : (year - 1980)
        let time = UInt16(((parts.hour ?? 0) << 11) | ((parts.minute ?? 0) << 5) | ((parts.second ?? 0) >> 1))
        let day = UInt16((y << 9) | ((parts.month ?? 1) << 5) | (parts.day ?? 1))
        return (time, day)
    }
}

private extension Data {
    mutating func appendUInt16(_ value: UInt16) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
    }

    mutating func appendUInt32(_ value: UInt32) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 24) & 0xFF))
    }
}
