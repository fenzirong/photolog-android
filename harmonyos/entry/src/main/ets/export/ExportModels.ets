/**
 * Export domain logic for 图志 HarmonyOS: ordering, file naming, and the caption document.
 *
 * This file is deliberately **self-contained — it imports nothing**. Two reasons:
 *
 * 1. It is the part of the app whose correctness cannot be seen by looking at a screen: it
 *    decides what ends up inside the generated archive. Keeping it free of platform APIs is
 *    what lets `tools/verify-export.mjs` run *this exact source* under Node and check the
 *    bytes, instead of a hand-written copy that can drift.
 * 2. The UTF-8 encoder needs byte-exact behaviour on both runtimes, so it is written against
 *    the language, not against `util.TextEncoder` or any other platform helper whose edge
 *    cases differ.
 *
 * ArkTS constraints observed throughout: no `any`, no `enum` (string-literal unions instead),
 * explicit types everywhere, no structural object literals without a declared interface.
 */

/** How the caption file is written. */
export type CaptionFormat = 'markdown' | 'html' | 'text';

/** Which photos go into an export. */
export type ExportScope = 'all' | 'withCaption' | 'recent';

/**
 * The export knobs.
 *
 * `lossless` is the one that matters: `true` copies the stored original byte for byte and every
 * other field is then ignored.
 */
export interface ExportOptions {
  lossless: boolean;
  jpegQuality: number;
  maxLongEdge: number;
  includeCaptions: boolean;
  captionFormat: CaptionFormat;
  numbered: boolean;
  useCaptionAsName: boolean;
}

/**
 * The library row this module works from.
 *
 * Structurally the `photos` table, declared here rather than imported so the file stays
 * dependency-free — the RDB layer maps its `ResultSet` into this shape.
 */
export interface PhotoRecord {
  id: number;
  caption: string;
  fileName: string;
  originalName: string;
  mimeType: string;
  width: number;
  height: number;
  sizeBytes: number;
  sha256: string;
  capturedAt: number;
  addedAt: number;
  source: string;
  sortIndex: number;
}

/** One photo's place in an export. */
export interface ExportEntry {
  photo: PhotoRecord;
  index: number;
  name: string;
  mimeType: string;
}

export const IMAGES_DIR: string = 'images';

/** U+FEFF, written out as EF BB BF by `utf8Encode`. */
export const BOM: string = '\uFEFF';

const NO_CAPTION: string = '（无说明）';
const FALLBACK_NAME: string = 'photo';
const MAX_NAME_CODE_POINTS: number = 60;

/** Longest prefix of `raw` holding at most `limit` code points, never splitting a surrogate pair. */
export function takeCodePoints(raw: string, limit: number): string {
  let count = 0;
  let i = 0;
  while (i < raw.length) {
    const code = raw.charCodeAt(i);
    if (code >= 0xd800 && code <= 0xdbff && i + 1 < raw.length) {
      const low = raw.charCodeAt(i + 1);
      i += (low >= 0xdc00 && low <= 0xdfff) ? 2 : 1;
    } else {
      i += 1;
    }
    count += 1;
    if (count === limit) {
      break;
    }
  }
  return raw.substring(0, i);
}

/** True for a single character that is illegal in a file name on at least one target platform. */
function isUnsafeChar(ch: string): boolean {
  const code = ch.charCodeAt(0);
  // Control characters cover the newlines and tabs a multi-line caption contains, which are
  // illegal everywhere rather than merely awkward.
  if (code < 0x20 || code === 0x7f) {
    return true;
  }
  return '\\/:*?"<>|'.indexOf(ch) >= 0;
}

function isHighSurrogate(code: number): boolean {
  return code >= 0xd800 && code <= 0xdbff;
}

function isLowSurrogate(code: number): boolean {
  return code >= 0xdc00 && code <= 0xdfff;
}

/**
 * The UTF-8 bytes of a string, implemented here so both runtimes agree byte for byte.
 *
 * The length pass and the write pass below are deliberately **identical in structure**. They
 * used to differ — the length pass accepted any high surrogate followed by *any* second unit as
 * a four-byte pair, while the write pass required a genuine low surrogate — and the result was
 * an output array with unwritten trailing zero bytes for input like `"\uD83Ca"`.
 *
 * Unpaired surrogates become U+FFFD rather than being encoded as themselves. Writing them out
 * directly produces CESU-8/WTF-8 (`ED A0 BC`), which is *not* valid UTF-8, and a file name
 * inside a ZIP is the last place that should hold a malformed byte sequence.
 */
export function utf8Encode(input: string): Uint8Array {
  let size = 0;
  let i = 0;
  while (i < input.length) {
    const code = input.charCodeAt(i);
    if (code < 0x80) {
      size += 1;
      i += 1;
    } else if (code < 0x800) {
      size += 2;
      i += 1;
    } else if (isHighSurrogate(code) && i + 1 < input.length && isLowSurrogate(input.charCodeAt(i + 1))) {
      size += 4;
      i += 2;
    } else {
      // A BMP character, or an unpaired surrogate emitted as U+FFFD: three bytes either way.
      size += 3;
      i += 1;
    }
  }

  const out = new Uint8Array(size);
  let at = 0;
  i = 0;
  while (i < input.length) {
    const code = input.charCodeAt(i);
    if (code < 0x80) {
      out[at] = code;
      at += 1;
      i += 1;
    } else if (code < 0x800) {
      out[at] = 0xc0 | (code >> 6);
      out[at + 1] = 0x80 | (code & 0x3f);
      at += 2;
      i += 1;
    } else if (isHighSurrogate(code) && i + 1 < input.length && isLowSurrogate(input.charCodeAt(i + 1))) {
      const point = 0x10000 + ((code - 0xd800) << 10) + (input.charCodeAt(i + 1) - 0xdc00);
      out[at] = 0xf0 | (point >> 18);
      out[at + 1] = 0x80 | ((point >> 12) & 0x3f);
      out[at + 2] = 0x80 | ((point >> 6) & 0x3f);
      out[at + 3] = 0x80 | (point & 0x3f);
      at += 4;
      i += 2;
    } else if (code >= 0xd800 && code <= 0xdfff) {
      out[at] = 0xef;
      out[at + 1] = 0xbf;
      out[at + 2] = 0xbd;
      at += 3;
      i += 1;
    } else {
      out[at] = 0xe0 | (code >> 12);
      out[at + 1] = 0x80 | ((code >> 6) & 0x3f);
      out[at + 2] = 0x80 | (code & 0x3f);
      at += 3;
      i += 1;
    }
  }
  return out;
}

/** The extension to store or export under. Unknown types keep an honest `bin`. */
export function extensionForMime(mime: string): string {
  const m = mime.trim().toLowerCase();
  if (m === 'image/jpeg' || m === 'image/jpg' || m === 'image/pjpeg') {
    return 'jpg';
  }
  if (m === 'image/png') {
    return 'png';
  }
  if (m === 'image/webp') {
    return 'webp';
  }
  if (m === 'image/gif') {
    return 'gif';
  }
  if (m === 'image/bmp' || m === 'image/x-ms-bmp') {
    return 'bmp';
  }
  if (m === 'image/heic' || m === 'image/heif' || m === 'image/heic-sequence') {
    return 'heic';
  }
  if (m === 'image/avif') {
    return 'avif';
  }
  if (m === 'image/tiff') {
    return 'tiff';
  }
  return 'bin';
}

const WINDOWS_RESERVED: string[] = [
  'CON', 'PRN', 'AUX', 'NUL',
  'COM1', 'COM2', 'COM3', 'COM4', 'COM5', 'COM6', 'COM7', 'COM8', 'COM9',
  'LPT1', 'LPT2', 'LPT3', 'LPT4', 'LPT5', 'LPT6', 'LPT7', 'LPT8', 'LPT9'
];

function isWindowsReserved(name: string): boolean {
  const upper = name.toUpperCase();
  for (let i = 0; i < WINDOWS_RESERVED.length; i++) {
    if (WINDOWS_RESERVED[i] === upper) {
      return true;
    }
  }
  return false;
}

function collapseSpaces(raw: string): string {
  let out = '';
  let previousWasSpace = false;
  for (let i = 0; i < raw.length; i++) {
    const ch = raw.charAt(i);
    if (ch === ' ') {
      if (!previousWasSpace) {
        out += ch;
      }
      previousWasSpace = true;
    } else {
      out += ch;
      previousWasSpace = false;
    }
  }
  return out;
}

function trimSpaces(raw: string): string {
  let start = 0;
  let end = raw.length;
  while (start < end && raw.charAt(start) === ' ') {
    start += 1;
  }
  while (end > start && raw.charAt(end - 1) === ' ') {
    end -= 1;
  }
  return raw.substring(start, end);
}

function trimDots(raw: string): string {
  let start = 0;
  let end = raw.length;
  while (start < end && raw.charAt(start) === '.') {
    start += 1;
  }
  while (end > start && raw.charAt(end - 1) === '.') {
    end -= 1;
  }
  return raw.substring(start, end);
}

/**
 * The order and the file names of an export.
 *
 * Naming rule in one line: **the image is named after the caption under it** when the photo has
 * one, otherwise after the source file name. `photos` must arrive already in the user's order
 * (`sortIndex` ascending) — preserving that order is the point of the feature.
 */
export class ExportNaming {
  static plan(photos: PhotoRecord[], scope: ExportScope, options: ExportOptions): ExportEntry[] {
    let ordered: PhotoRecord[];
    if (scope === 'withCaption') {
      ordered = [];
      for (let i = 0; i < photos.length; i++) {
        if (photos[i].caption.trim().length > 0) {
          ordered.push(photos[i]);
        }
      }
    } else if (scope === 'recent') {
      const byAdded: PhotoRecord[] = photos.slice(0);
      byAdded.sort((a: PhotoRecord, b: PhotoRecord): number => b.addedAt - a.addedAt);
      const newest: PhotoRecord[] = byAdded.slice(0, 20);
      newest.sort((a: PhotoRecord, b: PhotoRecord): number => a.sortIndex - b.sortIndex);
      ordered = newest;
    } else {
      ordered = photos.slice(0);
    }

    const used: string[] = [];
    const plan: ExportEntry[] = [];
    for (let position = 0; position < ordered.length; position++) {
      const photo = ordered[position];
      const extension = options.lossless ? extensionForMime(photo.mimeType) : 'jpg';
      const base = ExportNaming.baseName(photo, options);
      const prefix = options.numbered ? ExportNaming.padIndex(position + 1) : '';
      let name = prefix + base + '.' + extension;
      let suffix = 2;
      while (ExportNaming.containsName(used, name)) {
        name = prefix + base + '_' + suffix + '.' + extension;
        suffix += 1;
      }
      used.push(name.toLowerCase());
      plan.push({
        photo: photo,
        index: position + 1,
        name: name,
        mimeType: options.lossless ? photo.mimeType : 'image/jpeg'
      });
    }
    return plan;
  }

  /** A file name for the single-photo export, without an order prefix. */
  static suggestedName(photo: PhotoRecord, options: ExportOptions): string {
    return ExportNaming.baseName(photo, options) + '.' + extensionForMime(photo.mimeType);
  }

  /**
   * What the file is called, before the order prefix and the extension.
   *
   * The caption wins when there is one — that is the feature. Everything else is a fallback
   * chain: the source app's own name, then the name this app generated, then the literal
   * `photo` if even that sanitises away to nothing.
   */
  static baseName(photo: PhotoRecord, options: ExportOptions): string {
    if (options.useCaptionAsName) {
      const caption = photo.caption.trim();
      if (caption.length > 0) {
        return ExportNaming.sanitize(caption);
      }
    }
    const original = ExportNaming.stripExtension(photo.originalName);
    if (original.length > 0) {
      return ExportNaming.sanitize(original);
    }
    return ExportNaming.sanitize(ExportNaming.stripExtension(photo.fileName));
  }

  /**
   * Turns arbitrary user text into a name that survives every filesystem this archive may land
   * on.
   *
   * Chinese needs no special handling and gets none: CJK ideographs, full-width punctuation
   * (`：`, `？`, `｜`) and emoji are all legal in a file name on HarmonyOS, Windows, macOS and
   * Linux, so the filter only removes what is actually illegal. Notably it does **not** touch
   * `：` — the ASCII `:` is illegal on Windows, the full-width one is a different character and
   * is fine, and rewriting it would mangle a Chinese sentence for nothing.
   */
  static sanitize(raw: string): string {
    let filtered = '';
    let i = 0;
    while (i < raw.length) {
      const code = raw.charCodeAt(i);
      if (code >= 0xd800 && code <= 0xdbff && i + 1 < raw.length) {
        const low = raw.charCodeAt(i + 1);
        if (low >= 0xdc00 && low <= 0xdfff) {
          filtered += raw.substring(i, i + 2);
          i += 2;
          continue;
        }
      }
      filtered += isUnsafeChar(raw.charAt(i)) ? '_' : raw.charAt(i);
      i += 1;
    }

    let out = collapseSpaces(filtered);
    out = trimSpaces(out);
    out = trimDots(out);
    out = takeCodePoints(out, MAX_NAME_CODE_POINTS);
    out = trimSpaces(out);
    out = trimDots(out);
    if (out.length === 0) {
      out = FALLBACK_NAME;
    }
    if (isWindowsReserved(out)) {
      out = '_' + out;
    }
    return out;
  }

  private static padIndex(index: number): string {
    if (index < 10) {
      return '00' + index + '_';
    }
    if (index < 100) {
      return '0' + index + '_';
    }
    return '' + index + '_';
  }

  private static containsName(used: string[], candidate: string): boolean {
    const lower = candidate.toLowerCase();
    for (let i = 0; i < used.length; i++) {
      if (used[i] === lower) {
        return true;
      }
    }
    return false;
  }

  private static stripExtension(name: string): string {
    const dot = name.lastIndexOf('.');
    if (dot <= 0) {
      return name;
    }
    return name.substring(0, dot);
  }
}

/**
 * The "图片 + 图下文字说明" document.
 *
 * The order of the entries in the file is the order of the photos, and each caption sits
 * directly under its image — which is the requirement, and also the only arrangement that
 * survives being copied into a chat or a document.
 */
export class CaptionDocument {
  static build(plan: ExportEntry[], options: ExportOptions, exportedAt: number): string {
    if (options.captionFormat === 'html') {
      return CaptionDocument.html(plan, options, exportedAt);
    }
    if (options.captionFormat === 'text') {
      return CaptionDocument.text(plan, options, exportedAt);
    }
    return CaptionDocument.markdown(plan, options, exportedAt);
  }

  static fileName(format: CaptionFormat): string {
    if (format === 'html') {
      return 'captions.html';
    }
    if (format === 'text') {
      return 'captions.txt';
    }
    return 'captions.md';
  }

  static mimeType(format: CaptionFormat): string {
    if (format === 'html') {
      return 'text/html';
    }
    if (format === 'text') {
      return 'text/plain';
    }
    return 'text/markdown';
  }

  private static metadata(plan: ExportEntry[], options: ExportOptions, exportedAt: number): string[][] {
    let annotated = 0;
    for (let i = 0; i < plan.length; i++) {
      if (plan[i].photo.caption.trim().length > 0) {
        annotated += 1;
      }
    }
    const mode = options.lossless
      ? '无损（原样复制，未重新编码，EXIF 保留）'
      : '重新编码 JPEG（质量 ' + options.jpegQuality
        + (options.maxLongEdge > 0 ? '，最长边 ' + options.maxLongEdge + 'px' : '，原始尺寸') + '）';
    return [
      ['导出时间', CaptionDocument.formatStamp(exportedAt)],
      ['照片数量', '' + plan.length],
      ['图片目录', IMAGES_DIR + '/'],
      ['图片模式', mode],
      ['已写说明', annotated + ' / ' + plan.length]
    ];
  }

  private static markdown(plan: ExportEntry[], options: ExportOptions, exportedAt: number): string {
    const meta = CaptionDocument.metadata(plan, options, exportedAt);
    let out = '# 图志导出\n\n';
    for (let i = 0; i < meta.length; i++) {
      out += '- ' + meta[i][0] + '：' + meta[i][1] + '\n';
    }
    for (let i = 0; i < plan.length; i++) {
      const entry = plan[i];
      const label = CaptionDocument.indexLabel(entry.index);
      out += '\n---\n\n';
      out += '## ' + label + ' · ' + CaptionDocument.formatStamp(entry.photo.capturedAt) + '\n\n';
      out += '![' + label + '](' + IMAGES_DIR + '/' + entry.name + ')\n\n';
      out += (entry.photo.caption.length > 0 ? entry.photo.caption : NO_CAPTION) + '\n';
    }
    return out;
  }

  private static html(plan: ExportEntry[], options: ExportOptions, exportedAt: number): string {
    const meta = CaptionDocument.metadata(plan, options, exportedAt);
    let out = '<!DOCTYPE html>\n<html lang="zh-CN">\n<head>\n<meta charset="utf-8">\n';
    out += '<meta name="viewport" content="width=device-width, initial-scale=1">\n';
    out += '<title>图志导出</title>\n<style>\n';
    out += ':root{color-scheme:light dark}\n';
    out += 'body{margin:0;padding:24px;background:#f8f9fc;color:#191c20;line-height:1.7;';
    out += 'font-family:system-ui,-apple-system,"PingFang SC","HarmonyOS Sans SC",sans-serif}\n';
    out += 'h1{font-size:22px;margin:0 0 12px}\n';
    out += '.meta{color:#43474e;font-size:14px;margin:0 0 28px}\n';
    out += 'figure{margin:0 0 32px;background:#fff;border-radius:12px;overflow:hidden;';
    out += 'box-shadow:0 1px 3px rgba(0,0,0,.12)}\n';
    out += 'figure img{display:block;width:100%;height:auto;background:#e0e2ec}\n';
    out += 'figcaption{padding:14px 16px;font-size:15px}\n';
    out += 'figcaption .idx{display:inline-block;min-width:2.6em;color:#1d4e89;font-weight:600}\n';
    out += '@media (prefers-color-scheme:dark){body{background:#111318;color:#e2e2e6}';
    out += '.meta{color:#c3c6cf}figure{background:#1c1f24;box-shadow:none}';
    out += 'figure img{background:#43474e}figcaption .idx{color:#a6c8ff}}\n';
    out += '</style>\n</head>\n<body>\n<h1>图志导出</h1>\n<p class="meta">\n';
    for (let i = 0; i < meta.length; i++) {
      out += CaptionDocument.escape(meta[i][0]) + '：' + CaptionDocument.escape(meta[i][1]) + '<br>\n';
    }
    out += '</p>\n';
    for (let i = 0; i < plan.length; i++) {
      const entry = plan[i];
      const label = CaptionDocument.indexLabel(entry.index);
      const caption = entry.photo.caption.length > 0 ? entry.photo.caption : NO_CAPTION;
      out += '<figure>\n';
      out += '<img src="' + CaptionDocument.escape(IMAGES_DIR + '/' + entry.name)
        + '" alt="' + label + '" loading="lazy">\n';
      out += '<figcaption><span class="idx">' + label + '</span>'
        + CaptionDocument.escape(caption) + '</figcaption>\n';
      out += '</figure>\n';
    }
    out += '</body>\n</html>\n';
    return out;
  }

  private static text(plan: ExportEntry[], options: ExportOptions, exportedAt: number): string {
    const meta = CaptionDocument.metadata(plan, options, exportedAt);
    // The BOM is the only way a .txt can declare its encoding; without it a Chinese caption
    // opened in Notepad or Excel is mojibake.
    let out = BOM + '图志导出\n';
    for (let i = 0; i < meta.length; i++) {
      out += meta[i][0] + '：' + meta[i][1] + '\n';
    }
    out += '\n# 序号\t图片路径\t文字说明\n';
    for (let i = 0; i < plan.length; i++) {
      const entry = plan[i];
      const caption = entry.photo.caption.replace(/\n/g, ' ').replace(/\t/g, ' ');
      out += CaptionDocument.indexLabel(entry.index) + '\t' + IMAGES_DIR + '/' + entry.name + '\t'
        + (caption.length > 0 ? caption : NO_CAPTION) + '\n';
    }
    return out;
  }

  private static indexLabel(index: number): string {
    if (index < 10) {
      return '00' + index;
    }
    if (index < 100) {
      return '0' + index;
    }
    return '' + index;
  }

  private static formatStamp(millis: number): string {
    const d = new Date(millis);
    return CaptionDocument.pad2(d.getFullYear(), 4) + '-' + CaptionDocument.pad2(d.getMonth() + 1, 2)
      + '-' + CaptionDocument.pad2(d.getDate(), 2) + ' ' + CaptionDocument.pad2(d.getHours(), 2)
      + ':' + CaptionDocument.pad2(d.getMinutes(), 2) + ':' + CaptionDocument.pad2(d.getSeconds(), 2);
  }

  private static pad2(value: number, width: number): string {
    let s = '' + value;
    while (s.length < width) {
      s = '0' + s;
    }
    return s;
  }

  private static escape(raw: string): string {
    return raw
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;');
  }
}
