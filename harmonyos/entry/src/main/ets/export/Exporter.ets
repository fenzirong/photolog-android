import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { picker } from '@kit.CoreFileKit';
import { image } from '@kit.ImageKit';
import { util } from '@kit.ArkTS';
import {
  CaptionDocument,
  ExportNaming,
  ExportOptions,
  ExportScope,
  IMAGES_DIR,
  PhotoRecord
} from './ExportModels';
import { ZipSink, ZipSource, ZipWriter } from './ZipWriter';
import { PhotoRepository } from '../data/PhotoRepository';

export interface ExportProgress {
  done: number;
  total: number;
  current: string;
}

export interface ExportResult {
  written: number;
  skipped: number;
  total: number;
  message: string;
}

/**
 * Writes the library out to wherever the user picked.
 *
 * HarmonyOS has no Storage Access Framework; the equivalent is `DocumentViewPicker.save()`, which
 * takes the file names up front and returns one URI per file inside the folder the user chose.
 *
 * That shape is what makes the loose-file export a *single* picker interaction: every image name
 * plus the captions file name go in as `newFileNames`, and the user picks one destination folder.
 * Doing it one file at a time would mean N pickers.
 *
 * Both output paths call the same `writeImageBytes`, so the 无损 guarantee holds identically in
 * either.
 */
export class Exporter {
  private context: common.UIAbilityContext;
  private repository: PhotoRepository;

  constructor(context: common.UIAbilityContext) {
    this.context = context;
    this.repository = PhotoRepository.of(context);
  }

  /** One photo, straight to the file the user named. */
  async exportSingle(record: PhotoRecord, options: ExportOptions): Promise<ExportResult> {
    const source = this.repository.fileFor(record);
    if (!fileIo.accessSync(source)) {
      return Exporter.failed('原图文件已丢失');
    }
    const uris = await this.save([ExportNaming.suggestedName(record, options)]);
    if (uris.length === 0) {
      return Exporter.cancelled();
    }
    try {
      const target = fileIo.openSync(uris[0], fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.TRUNC);
      try {
        Exporter.writeImageBytes(source, record, target.fd, options);
      } finally {
        fileIo.closeSync(target);
      }
      return { written: 1, skipped: 0, total: 1, message: '已导出 1 张' };
    } catch (error) {
      return Exporter.failed(Exporter.describe(error));
    }
  }

  /**
   * The whole library as one ZIP: images plus the caption document.
   *
   * Entries are added in plan order, which is the library order — that ordering is the feature.
   */
  async exportZip(
    records: PhotoRecord[],
    scope: ExportScope,
    options: ExportOptions,
    onProgress: (progress: ExportProgress) => void
  ): Promise<ExportResult> {
    const plan = ExportNaming.plan(records, scope, options);
    if (plan.length === 0) {
      return Exporter.failed('没有符合条件的照片');
    }
    const uris = await this.save([`图志导出_${Exporter.stamp(Date.now())}.zip`]);
    if (uris.length === 0) {
      return Exporter.cancelled();
    }

    const sources: ZipSource[] = [];
    let skipped = 0;
    for (let i = 0; i < plan.length; i++) {
      const entry = plan[i];
      const path = this.repository.fileFor(entry.photo);
      if (fileIo.accessSync(path)) {
        sources.push(Exporter.imageSource(`${IMAGES_DIR}/${entry.name}`, path));
      } else {
        skipped += 1;
      }
    }
    if (options.includeCaptions) {
      const document = CaptionDocument.build(plan, options, Date.now());
      sources.push(Exporter.byteSource(CaptionDocument.fileName(options.captionFormat), Exporter.utf8(document)));
    }

    onProgress({ done: 0, total: plan.length, current: '打包中…' });

    try {
      const target = fileIo.openSync(uris[0], fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.TRUNC);
      try {
        const sink: ZipSink = {
          write: (chunk: Uint8Array): void => {
            // `byteOffset`/`byteLength`, not the whole buffer: a chunk is usually a view into a
            // reused 64 KiB read buffer, and writing `chunk.buffer` would emit stale bytes.
            fileIo.writeSync(target.fd, chunk.buffer, { offset: chunk.byteOffset, length: chunk.byteLength });
          }
        };
        ZipWriter.write(sources, sink, Date.now());
      } finally {
        fileIo.closeSync(target);
      }
    } catch (error) {
      return Exporter.failed(Exporter.describe(error));
    }

    onProgress({ done: plan.length, total: plan.length, current: '' });
    return Exporter.summarise(plan.length - skipped, skipped, plan.length);
  }

  /**
   * Loose images plus the caption document, all named up front.
   *
   * This is the export to keep: the result is browsable, editable, and re-importable by other
   * apps, and the file names are the captions.
   */
  async exportLoose(
    records: PhotoRecord[],
    scope: ExportScope,
    options: ExportOptions,
    onProgress: (progress: ExportProgress) => void
  ): Promise<ExportResult> {
    const plan = ExportNaming.plan(records, scope, options);
    if (plan.length === 0) {
      return Exporter.failed('没有符合条件的照片');
    }

    const names: string[] = [];
    for (let i = 0; i < plan.length; i++) {
      names.push(plan[i].name);
    }
    if (options.includeCaptions) {
      names.push(CaptionDocument.fileName(options.captionFormat));
    }

    const uris = await this.save(names);
    if (uris.length === 0) {
      return Exporter.cancelled();
    }

    let written = 0;
    let skipped = 0;
    try {
      for (let i = 0; i < plan.length; i++) {
        const entry = plan[i];
        onProgress({ done: i, total: plan.length, current: entry.name });
        const path = this.repository.fileFor(entry.photo);
        if (!fileIo.accessSync(path) || i >= uris.length) {
          skipped += 1;
          continue;
        }
        const target = fileIo.openSync(uris[i], fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.TRUNC);
        try {
          Exporter.writeImageBytes(path, entry.photo, target.fd, options);
        } finally {
          fileIo.closeSync(target);
        }
        written += 1;
      }

      if (options.includeCaptions && uris.length > plan.length) {
        const document = CaptionDocument.build(plan, options, Date.now());
        const target = fileIo.openSync(uris[plan.length], fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.TRUNC);
        try {
          const bytes = Exporter.utf8(document);
          fileIo.writeSync(target.fd, bytes.buffer, { offset: bytes.byteOffset, length: bytes.byteLength });
        } finally {
          fileIo.closeSync(target);
        }
      }
    } catch (error) {
      return Exporter.failed(Exporter.describe(error));
    }

    onProgress({ done: plan.length, total: plan.length, current: '' });
    return Exporter.summarise(written, skipped, plan.length);
  }

  /** The document on its own, for a user who already has the images somewhere else. */
  async exportCaptionsOnly(
    records: PhotoRecord[],
    scope: ExportScope,
    options: ExportOptions
  ): Promise<ExportResult> {
    const plan = ExportNaming.plan(records, scope, options);
    if (plan.length === 0) {
      return Exporter.failed('没有符合条件的照片');
    }
    const name = CaptionDocument.fileName(options.captionFormat);
    const uris = await this.save([name]);
    if (uris.length === 0) {
      return Exporter.cancelled();
    }
    try {
      const target = fileIo.openSync(uris[0], fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.TRUNC);
      try {
        const bytes = Exporter.utf8(CaptionDocument.build(plan, options, Date.now()));
        fileIo.writeSync(target.fd, bytes.buffer, { offset: bytes.byteOffset, length: bytes.byteLength });
      } finally {
        fileIo.closeSync(target);
      }
      return { written: plan.length, skipped: 0, total: plan.length, message: `已导出说明文件 ${name}` };
    } catch (error) {
      return Exporter.failed(Exporter.describe(error));
    }
  }

  // --- writing -------------------------------------------------------------- //

  /**
   * The one place image bytes reach an output.
   *
   * The lossless branch is a raw copy: the file on disk is exactly what the camera or the source
   * app produced, so the copy is bit-identical, EXIF and all. That is the whole feature — it
   * cannot be implemented by decoding and re-encoding.
   *
   * The lossy branch decodes and re-encodes through `ImagePacker`. It exists for the case where
   * the user explicitly wants smaller files, and it is kept visibly separate so that a future
   * reader can see at a glance which branch the "lossless" promise depends on.
   */
  private static writeImageBytes(
    sourcePath: string,
    record: PhotoRecord,
    targetFd: number,
    options: ExportOptions
  ): void {
    if (options.lossless) {
      const input = fileIo.openSync(sourcePath, fileIo.OpenMode.READ_ONLY);
      try {
        const buffer = new ArrayBuffer(64 * 1024);
        let read = fileIo.readSync(input.fd, buffer);
        while (read > 0) {
          fileIo.writeSync(targetFd, buffer, { offset: 0, length: read });
          read = fileIo.readSync(input.fd, buffer);
        }
      } finally {
        fileIo.closeSync(input);
      }
      return;
    }

    const bytes = Exporter.reencode(sourcePath, options);
    fileIo.writeSync(targetFd, bytes.buffer, { offset: bytes.byteOffset, length: bytes.byteLength });
  }

  private static reencode(sourcePath: string, options: ExportOptions): Uint8Array {
    const source = image.createImageSource(sourcePath);
    try {
      const pixelMap = source.createPixelMapSync();
      try {
        const packer = image.createImagePacker();
        try {
          const packing: image.PackingOption = {
            format: 'image/jpeg',
            quality: options.jpegQuality
          };
          return new Uint8Array(packer.packToDataSync(pixelMap, packing));
        } finally {
          packer.release();
        }
      } finally {
        pixelMap.release();
      }
    } finally {
      source.release();
    }
  }

  private static imageSource(entryName: string, path: string): ZipSource {
    const stat = fileIo.statSync(path);
    const source: ZipSource = {
      entryName: entryName,
      size: stat.size,
      stream: (consumer: (chunk: Uint8Array) => void): void => {
        const input = fileIo.openSync(path, fileIo.OpenMode.READ_ONLY);
        try {
          const buffer = new ArrayBuffer(64 * 1024);
          let read = fileIo.readSync(input.fd, buffer);
          while (read > 0) {
            consumer(new Uint8Array(buffer, 0, read));
            read = fileIo.readSync(input.fd, buffer);
          }
        } finally {
          fileIo.closeSync(input);
        }
      }
    };
    return source;
  }

  private static byteSource(entryName: string, bytes: Uint8Array): ZipSource {
    const source: ZipSource = {
      entryName: entryName,
      size: bytes.length,
      stream: (consumer: (chunk: Uint8Array) => void): void => {
        consumer(bytes);
      }
    };
    return source;
  }

  // --- picker --------------------------------------------------------------- //

  /** One picker interaction; returns one URI per requested name, or empty if cancelled. */
  private async save(fileNames: string[]): Promise<string[]> {
    const documentPicker = new picker.DocumentViewPicker(this.context);
    const saveOptions = new picker.DocumentSaveOptions();
    saveOptions.newFileNames = fileNames;
    try {
      return await documentPicker.save(saveOptions);
    } catch (error) {
      // The user backing out of the picker is a normal outcome, not a failure.
      return [];
    }
  }

  // --- helpers -------------------------------------------------------------- //

  private static utf8(value: string): Uint8Array {
    return new util.TextEncoder().encodeInto(value);
  }

  private static stamp(millis: number): string {
    const d = new Date(millis);
    const pad = (value: number): string => (value < 10 ? `0${value}` : `${value}`);
    return `${d.getFullYear()}${pad(d.getMonth() + 1)}${pad(d.getDate())}_`
      + `${pad(d.getHours())}${pad(d.getMinutes())}${pad(d.getSeconds())}`;
  }

  private static summarise(written: number, skipped: number, total: number): ExportResult {
    let message = `已导出 ${written} / ${total} 张`;
    if (skipped > 0) {
      message += `，${skipped} 张原图缺失被跳过`;
    }
    return { written: written, skipped: skipped, total: total, message: message };
  }

  private static failed(reason: string): ExportResult {
    return { written: 0, skipped: 0, total: 0, message: `导出失败：${reason}` };
  }

  private static cancelled(): ExportResult {
    return { written: 0, skipped: 0, total: 0, message: '已取消' };
  }

  private static describe(error: Object): string {
    if (error instanceof Error) {
      return error.message;
    }
    return `${error}`;
  }
}
