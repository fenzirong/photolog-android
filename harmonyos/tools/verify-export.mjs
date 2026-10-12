/**
 * Runs the HarmonyOS export logic under Node and checks the bytes it produces.
 *
 * ## Why this exists
 *
 * The HarmonyOS build cannot be verified on the machine this was written on: the HarmonyOS SDK
 * and `hvigor` are behind a Huawei developer account, and a `.hap` cannot even be *installed*
 * without signing material issued by Huawei's AGC. So the part of the port whose correctness
 * matters most — the export ordering, the file naming, and the bytes of the archive — is
 * verified here instead, off-device, against the very same source files.
 *
 * **It copies `*.ets` to `*.ts` and imports those.** It does not re-implement anything. A
 * hand-written JavaScript twin of the logic would pass while the shipped code was broken, which
 * is the one failure mode a test like this must not have.
 *
 * ## What it proves
 *
 * 1. The naming and ordering contract (caption becomes the file name, order preserved, the
 *    Chinese-specific edge cases).
 * 2. The archive is a real ZIP: correct signatures, correct CRC-32 (cross-checked against
 *    Node's own `zlib.crc32`), correct offsets, and the UTF-8 name flag set.
 * 3. **Windows' own extractor can read it**, Chinese entry names included — checked by actually
 *    calling `Expand-Archive` and reading the files back.
 *
 * Usage: `node harmonyos/tools/verify-export.mjs`
 */

import { execFileSync } from 'node:child_process';
import { copyFileSync, existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { crc32 as nodeCrc32 } from 'node:zlib';

const here = dirname(fileURLToPath(import.meta.url));
const harmonyRoot = join(here, '..');
const exportDir = join(harmonyRoot, 'entry', 'src', 'main', 'ets', 'export');
const workDir = join(harmonyRoot, '.verify');

// --------------------------------------------------------------------------- //
// Harness
// --------------------------------------------------------------------------- //

let passed = 0;
const failures = [];

function check(name, condition, detail) {
  if (condition) {
    passed += 1;
    console.log(`  ok   ${name}`);
  } else {
    failures.push(name);
    console.log(`  FAIL ${name}${detail === undefined ? '' : `  -> ${detail}`}`);
  }
}

function eq(name, actual, expected) {
  check(name, actual === expected, `expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`);
}

function section(title) {
  console.log(`\n${title}`);
}

// --------------------------------------------------------------------------- //
// Load the real sources
// --------------------------------------------------------------------------- //

rmSync(workDir, { recursive: true, force: true });
mkdirSync(workDir, { recursive: true });

for (const name of ['ExportModels', 'ZipWriter']) {
  const source = readFileSync(join(exportDir, `${name}.ets`), 'utf8');
  // ArkTS imports carry no file extension; Node's ESM resolver requires one. Rewriting the
  // specifier here is what lets the same source be both compiled by DevEco and executed here.
  const rewritten = source.replace(/from '\.\/ExportModels'/g, "from './ExportModels.ts'");
  writeFileSync(join(workDir, `${name}.ts`), rewritten);
}

const models = await import(pathToFileURL(join(workDir, 'ExportModels.ts')).href);
const zip = await import(pathToFileURL(join(workDir, 'ZipWriter.ts')).href);

const { ExportNaming, CaptionDocument, utf8Encode, IMAGES_DIR } = models;
const { ZipWriter, Crc32 } = zip;

/** A library row with the fields these tests care about. */
function photo(id, over) {
  const base = {
    id,
    caption: '',
    fileName: `g_${id}.jpg`,
    originalName: `IMG_${String(id).padStart(4, '0')}.jpg`,
    mimeType: 'image/jpeg',
    width: 4000,
    height: 3000,
    sizeBytes: 1024 * id,
    sha256: `sha${id}`,
    capturedAt: 1_760_000_000_000 + id * 1000,
    addedAt: 1_760_000_000_000 + id * 1000,
    source: 'GALLERY',
    sortIndex: id,
  };
  return Object.assign(base, over ?? {});
}

function options(over) {
  return Object.assign({
    lossless: true,
    jpegQuality: 95,
    maxLongEdge: 0,
    includeCaptions: true,
    captionFormat: 'markdown',
    numbered: true,
    useCaptionAsName: true,
  }, over ?? {});
}

// --------------------------------------------------------------------------- //
// Order and prefix
// --------------------------------------------------------------------------- //

section('order and prefix');

{
  const plan = ExportNaming.plan([photo(1), photo(2), photo(3)], 'all', options());
  eq('plan preserves library order', plan.map((e) => e.name).join(','), '001_IMG_0001.jpg,002_IMG_0002.jpg,003_IMG_0003.jpg');
  eq('plan preserves ids', plan.map((e) => e.photo.id).join(','), '1,2,3');
}

{
  const plan = ExportNaming.plan([photo(1), photo(2)], 'all', options({ numbered: false }));
  eq('numeric prefix can be omitted', plan.map((e) => e.name).join(','), 'IMG_0001.jpg,IMG_0002.jpg');
}

{
  const library = [];
  for (let i = 1; i <= 25; i++) {
    library.push(photo(i, { addedAt: i, sortIndex: i }));
  }
  const plan = ExportNaming.plan(library, 'recent', options());
  eq('recent takes 20', plan.length, 20);
  eq('recent takes the newest', plan[0].photo.id, 6);
  eq('recent still exports in library order', plan.map((e) => e.photo.sortIndex).join(','),
    plan.map((e) => e.photo.sortIndex).slice().sort((a, b) => a - b).join(','));
}

{
  const plan = ExportNaming.plan(
    [photo(1, { caption: '清晨的雾' }), photo(2), photo(3, { caption: '傍晚的云' })],
    'withCaption', options());
  eq('caption-only scope keeps annotated photos', plan.map((e) => e.photo.id).join(','), '1,3');
}

// --------------------------------------------------------------------------- //
// Caption becomes the file name
// --------------------------------------------------------------------------- //

section('caption becomes the file name');

{
  const plan = ExportNaming.plan(
    [photo(1, { caption: '清晨的雾' }), photo(2, { caption: '傍晚的云' })],
    'all', options());
  eq('chinese caption becomes the file name', plan.map((e) => e.name).join(','), '001_清晨的雾.jpg,002_傍晚的云.jpg');
}

{
  const plan = ExportNaming.plan([photo(1, { caption: '阳台：第 3 盆｜晴' })], 'all', options({ numbered: false }));
  eq('full-width punctuation kept', plan[0].name, '阳台：第 3 盆｜晴.jpg');
}

{
  const plan = ExportNaming.plan([photo(1, { caption: '旅行/第一天' })], 'all', options({ numbered: false }));
  eq('ascii path separator cannot create a directory', plan[0].name, '旅行_第一天.jpg');
}

{
  const plan = ExportNaming.plan([photo(1, { caption: '第一行\n第二行\t第三行' })], 'all', options({ numbered: false }));
  eq('multi-line caption flattened', plan[0].name, '第一行_第二行_第三行.jpg');
}

{
  const plan = ExportNaming.plan([photo(1, { caption: '字'.repeat(120) })], 'all', options({ numbered: false }));
  eq('long caption truncated to 60 code points', plan[0].name, `${'字'.repeat(60)}.jpg`);
}

{
  // 59 CJK characters then an emoji: code point 60 is the emoji, which must survive intact.
  const caption = `${'字'.repeat(59)}\u{1F305}`;
  const plan = ExportNaming.plan([photo(1, { caption })], 'all', options({ numbered: false }));
  const base = plan[0].name.replace(/\.jpg$/, '');
  eq('truncation keeps the emoji whole', base, `${'字'.repeat(59)}\u{1F305}`);
  check('truncation leaves no unpaired surrogate', !/[\uD800-\uDFFF]/.test(base.replace(/[\uD800-\uDBFF][\uDC00-\uDFFF]/g, '')));
}

{
  const plan = ExportNaming.plan([photo(1, { caption: '   ' })], 'all', options({ numbered: false }));
  eq('blank caption falls back to the original name', plan[0].name, 'IMG_0001.jpg');
}

{
  const plan = ExportNaming.plan(
    [photo(1, { caption: '随手拍' }), photo(2, { caption: '随手拍' })],
    'all', options({ numbered: false }));
  eq('duplicate captions get distinct names', plan.map((e) => e.name).join(','), '随手拍.jpg,随手拍_2.jpg');
}

{
  const plan = ExportNaming.plan([photo(1, { caption: '清晨的雾' })], 'all', options({ useCaptionAsName: false, numbered: false }));
  eq('naming can fall back to the original name', plan[0].name, 'IMG_0001.jpg');
}

{
  const plan = ExportNaming.plan([photo(1, { caption: 'CON' })], 'all', options({ numbered: false }));
  eq('windows device name is escaped', plan[0].name, '_CON.jpg');
}

{
  const plan = ExportNaming.plan([photo(1, { originalName: 'shot.png', mimeType: 'image/png' })], 'all', options());
  eq('lossless keeps the original extension', plan[0].name, '001_shot.png');
  const lossy = ExportNaming.plan([photo(1, { originalName: 'shot.png', mimeType: 'image/png' })], 'all', options({ lossless: false }));
  eq('lossy forces jpeg', lossy[0].name, '001_shot.jpg');
}

{
  const plan = ExportNaming.plan([photo(1, { caption: '截图.png', mimeType: 'image/jpeg' })], 'all', options({ numbered: false }));
  eq('extension comes from the bytes, not the caption', plan[0].name, '截图.png.jpg');
}

// --------------------------------------------------------------------------- //
// The caption document
// --------------------------------------------------------------------------- //

section('caption document');

{
  const plan = ExportNaming.plan(
    [photo(1, { caption: '第一张：清晨的雾' }), photo(2, { caption: '第二张：傍晚的云' })],
    'all', options());
  const doc = CaptionDocument.build(plan, options(), 1_760_000_000_000);

  const firstImage = doc.indexOf(`![001](${IMAGES_DIR}/${plan[0].name})`);
  const firstCaption = doc.indexOf('第一张：清晨的雾');
  const secondImage = doc.indexOf(`![002](${IMAGES_DIR}/${plan[1].name})`);
  const secondCaption = doc.indexOf('第二张：傍晚的云');

  check('markdown: first image present', firstImage >= 0);
  check('markdown: caption follows its own image', firstCaption > firstImage);
  check('markdown: second image follows the first caption', secondImage > firstCaption);
  check('markdown: second caption follows its own image', secondCaption > secondImage);
  check('markdown: image path matches the exported name', doc.includes(`images/${plan[0].name}`));
}

{
  const plan = ExportNaming.plan([photo(1)], 'all', options());
  const md = CaptionDocument.build(plan, options({ captionFormat: 'markdown' }), 0);
  const txt = CaptionDocument.build(plan, options({ captionFormat: 'text' }), 0);
  check('markdown marks a missing caption', md.includes('（无说明）'));
  check('text marks a missing caption', txt.includes('（无说明）'));
}

{
  const plan = ExportNaming.plan([photo(1, { caption: '清晨的雾' })], 'all', options());
  const txtBytes = Buffer.from(CaptionDocument.build(plan, options({ captionFormat: 'text' }), 0), 'utf8');
  check('captions.txt starts with a UTF-8 BOM',
    txtBytes[0] === 0xef && txtBytes[1] === 0xbb && txtBytes[2] === 0xbf,
    [...txtBytes.subarray(0, 3)].join(','));

  const md = CaptionDocument.build(plan, options({ captionFormat: 'markdown' }), 0);
  const html = CaptionDocument.build(plan, options({ captionFormat: 'html' }), 0);
  check('markdown carries no BOM', md.charCodeAt(0) !== 0xfeff && md.startsWith('#'));
  check('html carries no BOM', html.charCodeAt(0) !== 0xfeff && html.startsWith('<!DOCTYPE html>'));
  check('html declares its encoding', html.includes('<meta charset="utf-8">'));
}

{
  const plan = ExportNaming.plan([photo(1, { caption: '<script>alert(1)</script> & "q"' })], 'all', options());
  const html = CaptionDocument.build(plan, options({ captionFormat: 'html' }), 0);
  check('html escapes script tags', html.includes('&lt;script&gt;alert(1)&lt;/script&gt;'));
  check('html escapes ampersand', html.includes('&amp;'));
  check('html escapes quotes', html.includes('&quot;q&quot;'));
  check('html has no raw script tag', !html.includes('<script>'));
}

{
  const plan = ExportNaming.plan([photo(1)], 'all', options());
  const lossless = CaptionDocument.build(plan, options({ lossless: true }), 0);
  const lossy = CaptionDocument.build(plan, options({ lossless: false, jpegQuality: 90 }), 0);
  check('document records lossless mode', lossless.includes('无损'));
  check('document records lossy mode', lossy.includes('质量 90'));
}

// --------------------------------------------------------------------------- //
// UTF-8 encoder
// --------------------------------------------------------------------------- //

section('utf-8 encoder');

{
  eq('ascii', Buffer.from(utf8Encode('abc')).toString('hex'), Buffer.from('abc', 'utf8').toString('hex'));
  eq('chinese', Buffer.from(utf8Encode('清晨的雾')).toString('hex'), Buffer.from('清晨的雾', 'utf8').toString('hex'));
  eq('emoji', Buffer.from(utf8Encode('\u{1F305}')).toString('hex'), Buffer.from('\u{1F305}', 'utf8').toString('hex'));
  eq('mixed', Buffer.from(utf8Encode('第1天\u{1F305}晴')).toString('hex'), Buffer.from('第1天\u{1F305}晴', 'utf8').toString('hex'));
  eq('lone surrogate becomes U+FFFD', Buffer.from(utf8Encode('\uD83C')).toString('hex'), 'efbfbd');

  // A high surrogate followed by something that is not a low surrogate. The length pass and the
  // write pass must agree here, or the output array ends in unwritten zero bytes — which is the
  // shape the original implementation got wrong.
  const split = utf8Encode('\uD83Ca');
  eq('high surrogate + ascii encodes as U+FFFD then a', Buffer.from(split).toString('hex'), 'efbfbd61');
  eq('no trailing unwritten bytes', split.length, 4);

  // A lone low surrogate is unpaired too.
  eq('lone low surrogate becomes U+FFFD', Buffer.from(utf8Encode('\uDC00')).toString('hex'), 'efbfbd');
}

// --------------------------------------------------------------------------- //
// The archive
// --------------------------------------------------------------------------- //

section('archive');

const IMAGE_BYTES = Buffer.from([0xff, 0xd8, 0xff, 0xe0, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77]);
const CAPTION_ENTRY = 'captions.md';

function chunkedSource(entryName, bytes, chunkSize) {
  return {
    entryName,
    size: bytes.length,
    stream(consumer) {
      for (let at = 0; at < bytes.length; at += chunkSize) {
        consumer(bytes.subarray(at, Math.min(at + chunkSize, bytes.length)));
      }
    },
  };
}

{
  const plan = ExportNaming.plan([photo(1, { caption: '清晨的雾' })], 'all', options());
  const captionBytes = Buffer.from(CaptionDocument.build(plan, options(), 1_760_000_000_000), 'utf8');
  const imageEntry = `${IMAGES_DIR}/${plan[0].name}`;
  const sources = [
    chunkedSource(imageEntry, IMAGE_BYTES, 3),
    chunkedSource(CAPTION_ENTRY, captionBytes, 7),
  ];

  const chunks = [];
  let written = 0;
  const sink = {
    write(chunk) {
      chunks.push(Buffer.from(chunk));
      written += chunk.length;
    },
  };

  const reported = ZipWriter.write(sources, sink, 1_760_000_000_000);
  const archive = Buffer.concat(chunks);

  eq('reported size matches bytes written', reported, archive.length);
  eq('local header signature', archive.readUInt32LE(0), 0x04034b50);
  eq('entry name is utf-8', archive.subarray(30, 30 + Buffer.byteLength(imageEntry)).toString('utf8'), imageEntry);

  const flags = archive.readUInt16LE(6);
  eq('EFS (utf-8 name) flag is set', flags & 0x0800, 0x0800);
  eq('no data descriptor flag', flags & 0x0008, 0);

  const storedCrc = archive.readUInt32LE(14);
  eq('crc matches node zlib.crc32', storedCrc, nodeCrc32(IMAGE_BYTES) >>> 0);
  eq('stored size', archive.readUInt32LE(18), IMAGE_BYTES.length);
  eq('uncompressed size', archive.readUInt32LE(22), IMAGE_BYTES.length);
  eq('compression method is STORE', archive.readUInt16LE(8), 0);

  const eocdAt = archive.length - 22;
  eq('end of central directory signature', archive.readUInt32LE(eocdAt), 0x06054b50);
  eq('entry count', archive.readUInt16LE(eocdAt + 10), 2);

  // Sum of every local header + name + data that precedes the central directory.
  const imageBlock = 30 + Buffer.byteLength(imageEntry) + IMAGE_BYTES.length;
  const captionBlock = 30 + Buffer.byteLength(CAPTION_ENTRY) + captionBytes.length;
  eq('central directory offset', archive.readUInt32LE(eocdAt + 16), imageBlock + captionBlock);

  // The real test: hand it to Windows' own extractor and read it back.
  const archivePath = join(workDir, 'export.zip');
  const extractDir = join(workDir, 'extracted');
  writeFileSync(archivePath, archive);
  mkdirSync(extractDir, { recursive: true });

  let extractError = '';
  try {
    execFileSync('powershell.exe', [
      '-NoProfile', '-NonInteractive', '-Command',
      `Expand-Archive -LiteralPath '${archivePath}' -DestinationPath '${extractDir}' -Force`,
    ], { stdio: 'pipe' });
  } catch (error) {
    extractError = String(error.stderr ?? error.message).slice(0, 400);
  }
  check('windows Expand-Archive accepts the archive', extractError === '', extractError);

  if (extractError === '') {
    const imagePath = join(extractDir, IMAGES_DIR, plan[0].name);
    const captionPath = join(extractDir, CAPTION_ENTRY);
    check('extracted the chinese-named image', existsSync(imagePath), imagePath);
    if (existsSync(imagePath)) {
      check('extracted image bytes are identical', Buffer.compare(readFileSync(imagePath), IMAGE_BYTES) === 0);
    }
    check('extracted the captions file', existsSync(captionPath));
    if (existsSync(captionPath)) {
      const readBack = readFileSync(captionPath).toString('utf8');
      check('extracted captions keep the chinese text', readBack.includes('清晨的雾'));
      check('extracted captions reference the chinese image name', readBack.includes(`images/${plan[0].name}`));
    }
  }
}

{
  // An empty archive must still be a valid ZIP, not a zero-byte file.
  const chunks = [];
  ZipWriter.write([], { write: (chunk) => chunks.push(Buffer.from(chunk)) }, 0);
  const archive = Buffer.concat(chunks);
  eq('empty archive is 22 bytes', archive.length, 22);
  eq('empty archive signature', archive.readUInt32LE(0), 0x06054b50);
  eq('empty archive entry count', archive.readUInt16LE(10), 0);
}

// --------------------------------------------------------------------------- //

rmSync(workDir, { recursive: true, force: true });

console.log(`\n${passed} passed, ${failures.length} failed`);
if (failures.length > 0) {
  for (const name of failures) {
    console.log(`  FAILED: ${name}`);
  }
  process.exit(1);
}
console.log('export logic verified');
