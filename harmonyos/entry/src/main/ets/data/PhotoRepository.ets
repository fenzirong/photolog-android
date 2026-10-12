import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { image } from '@kit.ImageKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { PhotoRecord } from '../export/ExportModels';
import { PhotoDatabase } from './PhotoDatabase';

/**
 * The library: the files, and the rows that index them.
 *
 * The only place in the app that knows where the originals live, which is what keeps the
 * "never re-encode the original" rule enforceable — the export path can only read bytes through
 * `fileFor`, so it cannot accidentally overwrite the source.
 */
export class PhotoRepository {
  private static instance: PhotoRepository | undefined = undefined;

  private context: common.UIAbilityContext;

  private constructor(context: common.UIAbilityContext) {
    this.context = context;
  }

  static of(context: common.UIAbilityContext): PhotoRepository {
    if (PhotoRepository.instance === undefined) {
      PhotoRepository.instance = new PhotoRepository(context);
    }
    return PhotoRepository.instance;
  }

  /** Where the originals live. Created on first use. */
  originalsDir(): string {
    const dir = `${this.context.filesDir}/originals`;
    if (!fileIo.accessSync(dir)) {
      fileIo.mkdirSync(dir, true);
    }
    return dir;
  }

  /** The untouched original. Read-only by convention — nothing in this app writes to it. */
  fileFor(record: PhotoRecord): string {
    return `${this.originalsDir()}/${record.fileName}`;
  }

  /** Reserves a path for the camera to write into, before the capture starts. */
  newCapturePath(): string {
    const stamp = PhotoRepository.stamp(Date.now());
    let candidate = `${this.originalsDir()}/c_${stamp}.jpg`;
    let suffix = 1;
    while (fileIo.accessSync(candidate)) {
      candidate = `${this.originalsDir()}/c_${stamp}_${suffix}.jpg`;
      suffix += 1;
    }
    return candidate;
  }

  /**
   * Copies one incoming image into the library.
   *
   * The file is streamed to a temporary path first, hashing as it goes, and only then moved into
   * `originals`. Two consequences are deliberate: nothing half-written can become a library
   * entry, and the duplicate check runs before the copy is promoted — so re-sharing an image
   * costs a hash rather than a second copy on disk.
   *
   * The returned record has `id` and `sortIndex` left at 0; the caller assigns both when it
   * inserts, because only the database knows the next index.
   */
  async importUri(uri: string, source: string): Promise<PhotoRecord | undefined> {
    const tempPath = `${this.context.cacheDir}/photolog_import_${Date.now()}_${Math.floor(Math.random() * 100000)}.tmp`;
    let input: fileIo.File | undefined = undefined;
    let output: fileIo.File | undefined = undefined;
    try {
      input = fileIo.openSync(uri, fileIo.OpenMode.READ_ONLY);
      output = fileIo.openSync(
        tempPath,
        fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC
      );

      const digest = cryptoFramework.createMd('SHA256');
      const buffer = new ArrayBuffer(64 * 1024);
      let size = 0;
      let read = fileIo.readSync(input.fd, buffer);
      while (read > 0) {
        const chunk = new Uint8Array(buffer, 0, read);
        const blob: cryptoFramework.DataBlob = { data: chunk };
        await digest.update(blob);
        // `offset`/`length` are load-bearing: the buffer is a fixed 64 KiB and only the first
        // `read` bytes of it are this iteration's data.
        const writeOptions: fileIo.WriteOptions = { offset: 0, length: read };
        fileIo.writeSync(output.fd, buffer, writeOptions);
        size += read;
        read = fileIo.readSync(input.fd, buffer);
      }
      fileIo.closeSync(output);
      output = undefined;
      fileIo.closeSync(input);
      input = undefined;

      if (size <= 0) {
        return undefined;
      }

      const digestBlob = await digest.digest();
      const sha256 = PhotoRepository.toHex(digestBlob.data);

      const existing = await PhotoDatabase.findByHash(this.context, sha256);
      if (existing !== undefined) {
        return existing;
      }

      const displayName = PhotoRepository.displayNameOf(uri);
      const mimeType = PhotoRepository.mimeOf(displayName);
      const target = this.allocate('g', PhotoRepository.extensionFor(mimeType));
      fileIo.moveFileSync(tempPath, target);

      const bounds = PhotoRepository.measure(target);
      const now = Date.now();
      const record: PhotoRecord = {
        id: 0,
        caption: '',
        fileName: PhotoRepository.baseNameOf(target),
        originalName: displayName,
        mimeType: mimeType,
        width: bounds[0],
        height: bounds[1],
        sizeBytes: size,
        sha256: sha256,
        capturedAt: now,
        addedAt: now,
        source: source,
        sortIndex: 0
      };
      return record;
    } finally {
      if (input !== undefined) {
        fileIo.closeSync(input);
      }
      if (output !== undefined) {
        fileIo.closeSync(output);
      }
      if (fileIo.accessSync(tempPath)) {
        fileIo.unlinkSync(tempPath);
      }
    }
  }

  /**
   * Builds the row for a file the camera already wrote.
   *
   * The hash is left empty: the camera path is the one place the bytes are known to be new, and
   * hashing a 12 MP JPEG here would delay the shutter. Duplicate detection therefore does not
   * apply to camera captures, which is correct — taking the same photo twice is two photos.
   */
  registerCapture(path: string): PhotoRecord {
    const stat = fileIo.statSync(path);
    const bounds = PhotoRepository.measure(path);
    const now = Date.now();
    const record: PhotoRecord = {
      id: 0,
      caption: '',
      fileName: PhotoRepository.baseNameOf(path),
      originalName: '',
      mimeType: 'image/jpeg',
      width: bounds[0],
      height: bounds[1],
      sizeBytes: stat.size,
      sha256: '',
      capturedAt: now,
      addedAt: now,
      source: 'CAMERA',
      sortIndex: 0
    };
    return record;
  }

  deleteFiles(records: PhotoRecord[]): void {
    for (let i = 0; i < records.length; i++) {
      const path = this.fileFor(records[i]);
      if (fileIo.accessSync(path)) {
        fileIo.unlinkSync(path);
      }
    }
  }

  deleteAllFiles(): void {
    const dir = this.originalsDir();
    const entries = fileIo.listFileSync(dir);
    for (let i = 0; i < entries.length; i++) {
      fileIo.unlinkSync(`${dir}/${entries[i]}`);
    }
  }

  private allocate(prefix: string, extension: string): string {
    const stamp = PhotoRepository.stamp(Date.now());
    let candidate = `${this.originalsDir()}/${prefix}_${stamp}.${extension}`;
    let suffix = 1;
    while (fileIo.accessSync(candidate)) {
      candidate = `${this.originalsDir()}/${prefix}_${stamp}_${suffix}.${extension}`;
      suffix += 1;
    }
    return candidate;
  }

  // --- small helpers -------------------------------------------------------- //

  private static stamp(millis: number): string {
    const d = new Date(millis);
    return `${d.getFullYear()}${PhotoRepository.pad(d.getMonth() + 1)}${PhotoRepository.pad(d.getDate())}`
      + `_${PhotoRepository.pad(d.getHours())}${PhotoRepository.pad(d.getMinutes())}${PhotoRepository.pad(d.getSeconds())}`
      + `_${PhotoRepository.pad3(d.getMilliseconds())}`;
  }

  private static pad(value: number): string {
    return value < 10 ? `0${value}` : `${value}`;
  }

  private static pad3(value: number): string {
    if (value < 10) {
      return `00${value}`;
    }
    if (value < 100) {
      return `0${value}`;
    }
    return `${value}`;
  }

  private static baseNameOf(path: string): string {
    const slash = path.lastIndexOf('/');
    return slash < 0 ? path : path.substring(slash + 1);
  }

  private static displayNameOf(uri: string): string {
    const name = PhotoRepository.baseNameOf(uri);
    return name.length > 0 ? name : 'image';
  }

  private static mimeOf(name: string): string {
    const lower = name.toLowerCase();
    if (lower.endsWith('.png')) {
      return 'image/png';
    }
    if (lower.endsWith('.webp')) {
      return 'image/webp';
    }
    if (lower.endsWith('.gif')) {
      return 'image/gif';
    }
    if (lower.endsWith('.bmp')) {
      return 'image/bmp';
    }
    if (lower.endsWith('.heic') || lower.endsWith('.heif')) {
      return 'image/heic';
    }
    if (lower.endsWith('.avif')) {
      return 'image/avif';
    }
    return 'image/jpeg';
  }

  private static extensionFor(mimeType: string): string {
    if (mimeType === 'image/png') {
      return 'png';
    }
    if (mimeType === 'image/webp') {
      return 'webp';
    }
    if (mimeType === 'image/gif') {
      return 'gif';
    }
    if (mimeType === 'image/bmp') {
      return 'bmp';
    }
    if (mimeType === 'image/heic') {
      return 'heic';
    }
    if (mimeType === 'image/avif') {
      return 'avif';
    }
    return 'jpg';
  }

  /**
   * Pixel dimensions, read from the file header only.
   *
   * `createImageSource` does not decode until asked, so this costs a header read rather than a
   * full decode of a 12 MP photo. A failure is not fatal: the UI falls back to a square tile
   * when either dimension is 0.
   */
  private static measure(path: string): number[] {
    try {
      const source = image.createImageSource(path);
      const info = source.getImageInfoSync();
      const size: number[] = [info.size.width, info.size.height];
      source.release();
      return size;
    } catch (error) {
      return [0, 0];
    }
  }

  private static toHex(bytes: Uint8Array): string {
    let out = '';
    for (let i = 0; i < bytes.length; i++) {
      const value = bytes[i];
      out += PhotoRepository.hexDigit(value >> 4) + PhotoRepository.hexDigit(value & 0x0f);
    }
    return out;
  }

  private static hexDigit(value: number): string {
    return '0123456789abcdef'.charAt(value);
  }
}
