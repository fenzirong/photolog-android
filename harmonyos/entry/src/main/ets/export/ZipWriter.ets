/**
 * A minimal ZIP writer for 图志 HarmonyOS.
 *
 * The only import is the UTF-8 encoder, and it is an import on purpose: this file used to carry
 * its own copy of that function, which meant a bug in it had to be fixed twice and would only
 * be caught once. `tools/verify-export.mjs` rewrites the specifier to `./ExportModels.ts` when
 * it copies these sources for Node, so the same single implementation is what gets tested.
 *
 * ## Why not `@ohos.zlib`
 *
 * `zlib.compressFile` works on a path, not a stream, and gives no control over the archive's
 * entry names or their encoding flag. Chinese file names inside a ZIP are the single most
 * likely thing to break when the archive is opened on Windows, and the fix is one bit in the
 * general purpose flags — so the archive is written here instead, where that bit is reachable.
 *
 * ## Why STORE and not DEFLATE
 *
 * Every entry is a photo, and a JPEG/PNG/HEIC is already compressed: DEFLATE over it costs CPU
 * and saves approximately nothing. Method 0 (STORE) is therefore not a shortcut but the right
 * choice for this archive — and it removes the need for a compressor the runtime does not
 * expose as a stream API anyway.
 *
 * ## Layout produced
 *
 * ```
 * [local header][name][data]  ×N
 * [central directory header][name] ×N
 * [end of central directory]
 * ```
 *
 * The CRC of each entry is computed in a first pass over its bytes, because the local header
 * precedes the data and must already carry it. The alternative — a data descriptor with flag
 * bit 3 — is a less universally supported combination, and reading a local file twice costs
 * nothing next to being unable to open the result.
 */

import { utf8Encode } from './ExportModels';

/** Where the archive bytes go. Called repeatedly, in order, with non-empty chunks. */
export interface ZipSink {
  write(chunk: Uint8Array): void;
}

/**
 * One entry's bytes.
 *
 * `stream` may be called more than once: the writer makes a first pass to compute the CRC and
 * a second to emit. `size` must be exact, and `stream` must push exactly that many bytes.
 */
export interface ZipSource {
  entryName: string;
  size: number;
  stream(consumer: (chunk: Uint8Array) => void): void;
}

/** Table-driven CRC-32 (the reflected polynomial ZIP uses, 0xEDB88320). */
export class Crc32 {
  private static readonly TABLE: number[] = Crc32.buildTable();

  static begin(): number {
    return 0xffffffff;
  }

  static update(crc: number, bytes: Uint8Array): number {
    let c = crc;
    for (let i = 0; i < bytes.length; i++) {
      c = Crc32.TABLE[(c ^ bytes[i]) & 0xff] ^ (c >>> 8);
    }
    return c;
  }

  static finish(crc: number): number {
    return (crc ^ 0xffffffff) >>> 0;
  }

  private static buildTable(): number[] {
    const table: number[] = [];
    for (let n = 0; n < 256; n++) {
      let c = n;
      for (let k = 0; k < 8; k++) {
        c = ((c & 1) !== 0) ? (0xedb88320 ^ (c >>> 1)) : (c >>> 1);
      }
      table.push(c);
    }
    return table;
  }
}

/** Little-endian byte accumulator. */
class ByteBuffer {
  private bytes: number[] = [];

  u16(value: number): void {
    this.bytes.push(value & 0xff);
    this.bytes.push((value >>> 8) & 0xff);
  }

  u32(value: number): void {
    this.bytes.push(value & 0xff);
    this.bytes.push((value >>> 8) & 0xff);
    this.bytes.push((value >>> 16) & 0xff);
    this.bytes.push((value >>> 24) & 0xff);
  }

  append(chunk: Uint8Array): void {
    for (let i = 0; i < chunk.length; i++) {
      this.bytes.push(chunk[i]);
    }
  }

  toUint8Array(): Uint8Array {
    const out = new Uint8Array(this.bytes.length);
    for (let i = 0; i < this.bytes.length; i++) {
      out[i] = this.bytes[i];
    }
    return out;
  }
}

interface PreparedEntry {
  source: ZipSource;
  nameBytes: Uint8Array;
  crc: number;
  offset: number;
}

export class ZipWriter {
  /**
   * Writes a STORE-method archive of `sources` into `sink`.
   *
   * Entry order is preserved exactly — that order *is* the export order, which is the point of
   * the feature.
   */
  static write(sources: ZipSource[], sink: ZipSink, modifiedAt: number): number {
    const dosTime = ZipWriter.dosTime(modifiedAt);
    const dosDate = ZipWriter.dosDate(modifiedAt);

    // Pass 1: CRC of every entry, so each local header can carry it before the data follows.
    const crcs: number[] = [];
    for (let i = 0; i < sources.length; i++) {
      let crc = Crc32.begin();
      sources[i].stream((chunk: Uint8Array): void => {
        crc = Crc32.update(crc, chunk);
      });
      crcs.push(Crc32.finish(crc));
    }

    // Pass 2: local headers and data.
    const prepared: PreparedEntry[] = [];
    let offset = 0;
    for (let i = 0; i < sources.length; i++) {
      const source = sources[i];
      const nameBytes = utf8Encode(source.entryName);
      const header = new ByteBuffer();
      header.u32(0x04034b50);
      header.u16(20);
      // Bit 11 (EFS) declares the name is UTF-8. Set unconditionally: an ASCII name is valid
      // UTF-8, and the alternative is a per-name decision that is wrong exactly once.
      header.u16(0x0800);
      header.u16(0);
      header.u16(dosTime);
      header.u16(dosDate);
      header.u32(crcs[i]);
      header.u32(source.size);
      header.u32(source.size);
      header.u16(nameBytes.length);
      header.u16(0);
      const headerBytes = header.toUint8Array();

      sink.write(headerBytes);
      sink.write(nameBytes);
      source.stream((chunk: Uint8Array): void => {
        sink.write(chunk);
      });

      prepared.push({
        source: source,
        nameBytes: nameBytes,
        crc: crcs[i],
        offset: offset
      });
      offset += headerBytes.length + nameBytes.length + source.size;
    }

    // Central directory.
    const directory = new ByteBuffer();
    for (let i = 0; i < prepared.length; i++) {
      const entry = prepared[i];
      directory.u32(0x02014b50);
      directory.u16(20);
      directory.u16(20);
      directory.u16(0x0800);
      directory.u16(0);
      directory.u16(dosTime);
      directory.u16(dosDate);
      directory.u32(entry.crc);
      directory.u32(entry.source.size);
      directory.u32(entry.source.size);
      directory.u16(entry.nameBytes.length);
      directory.u16(0);
      directory.u16(0);
      directory.u16(0);
      directory.u16(0);
      directory.u32(0);
      directory.u32(entry.offset);
      directory.append(entry.nameBytes);
    }
    const directoryBytes = directory.toUint8Array();
    sink.write(directoryBytes);

    // End of central directory.
    const end = new ByteBuffer();
    end.u32(0x06054b50);
    end.u16(0);
    end.u16(0);
    end.u16(prepared.length);
    end.u16(prepared.length);
    end.u32(directoryBytes.length);
    end.u32(offset);
    end.u16(0);
    sink.write(end.toUint8Array());

    return offset + directoryBytes.length + 22;
  }

  /**
   * MS-DOS time, which is what the ZIP format stores.
   *
   * Seconds have two-second resolution by design of the format; the odd second is dropped
   * rather than rounded, which is what every other writer does.
   */
  private static dosTime(millis: number): number {
    const d = new Date(millis);
    return ((d.getHours() << 11) | (d.getMinutes() << 5) | (d.getSeconds() >> 1)) & 0xffff;
  }

  private static dosDate(millis: number): number {
    const d = new Date(millis);
    const year = d.getFullYear();
    // The format starts at 1980; anything earlier is clamped rather than wrapping to a
    // nonsensical future date.
    const y = year < 1980 ? 0 : (year - 1980);
    return ((y << 9) | ((d.getMonth() + 1) << 5) | d.getDate()) & 0xffff;
  }
}
