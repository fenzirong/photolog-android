import { common } from '@kit.AbilityKit';
import { relationalStore } from '@kit.ArkData';
import { PhotoRecord } from '../export/ExportModels';

/**
 * The library table.
 *
 * Mirrors the Android schema column for column, including the two decisions that carry the most
 * weight:
 *
 * - **The bytes are not here.** `fileName` points at a file under `filesDir/originals`, which
 *   holds exactly what the camera wrote or what the source app handed over. Keeping the original
 *   untouched is what makes 无损导出 possible at all.
 * - **`sortIndex` is the user's order, not a timestamp**, and it is a dense 1..n sequence:
 *   reordering rewrites the whole list anyway, so "index equals position" is worth more than
 *   fewer writes.
 *
 * `sha256` is the dedupe key, so re-sharing an image costs a hash rather than a second copy.
 */
const CREATE_TABLE: string = `CREATE TABLE IF NOT EXISTS photos (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  caption TEXT NOT NULL DEFAULT '',
  fileName TEXT NOT NULL,
  originalName TEXT NOT NULL DEFAULT '',
  mimeType TEXT NOT NULL DEFAULT 'image/jpeg',
  width INTEGER NOT NULL DEFAULT 0,
  height INTEGER NOT NULL DEFAULT 0,
  sizeBytes INTEGER NOT NULL DEFAULT 0,
  sha256 TEXT NOT NULL DEFAULT '',
  capturedAt INTEGER NOT NULL DEFAULT 0,
  addedAt INTEGER NOT NULL DEFAULT 0,
  source TEXT NOT NULL DEFAULT 'GALLERY',
  sortIndex INTEGER NOT NULL DEFAULT 0
)`;

const CREATE_HASH_INDEX: string = 'CREATE INDEX IF NOT EXISTS idx_photos_sha ON photos (sha256)';

export class PhotoDatabase {
  private static store: relationalStore.RdbStore | undefined = undefined;

  /** Opens (and on first run creates) the store. Safe to call repeatedly. */
  static async open(context: common.UIAbilityContext): Promise<relationalStore.RdbStore> {
    if (PhotoDatabase.store !== undefined) {
      return PhotoDatabase.store;
    }
    const config: relationalStore.StoreConfig = {
      name: 'photolog.db',
      securityLevel: relationalStore.SecurityLevel.S1
    };
    const store = await relationalStore.getRdbStore(context, config);
    await store.executeSql(CREATE_TABLE);
    await store.executeSql(CREATE_HASH_INDEX);
    PhotoDatabase.store = store;
    return store;
  }

  static async all(context: common.UIAbilityContext): Promise<PhotoRecord[]> {
    const store = await PhotoDatabase.open(context);
    const predicates = new relationalStore.RdbPredicates('photos');
    predicates.orderByAsc('sortIndex');
    const resultSet = await store.query(predicates);
    const records: PhotoRecord[] = [];
    try {
      while (resultSet.goToNextRow()) {
        records.push(PhotoDatabase.readRow(resultSet));
      }
    } finally {
      resultSet.close();
    }
    return records;
  }

  static async findOne(context: common.UIAbilityContext, id: number): Promise<PhotoRecord | undefined> {
    const store = await PhotoDatabase.open(context);
    const predicates = new relationalStore.RdbPredicates('photos');
    predicates.equalTo('id', id);
    const resultSet = await store.query(predicates);
    try {
      if (resultSet.goToNextRow()) {
        return PhotoDatabase.readRow(resultSet);
      }
      return undefined;
    } finally {
      resultSet.close();
    }
  }

  static async findByHash(context: common.UIAbilityContext, sha256: string): Promise<PhotoRecord | undefined> {
    const store = await PhotoDatabase.open(context);
    const predicates = new relationalStore.RdbPredicates('photos');
    predicates.equalTo('sha256', sha256);
    const resultSet = await store.query(predicates);
    try {
      if (resultSet.goToNextRow()) {
        return PhotoDatabase.readRow(resultSet);
      }
      return undefined;
    } finally {
      resultSet.close();
    }
  }

  static async maxSortIndex(context: common.UIAbilityContext): Promise<number> {
    const store = await PhotoDatabase.open(context);
    const resultSet = await store.querySql('SELECT MAX(sortIndex) AS maxSort FROM photos');
    try {
      if (resultSet.goToNextRow()) {
        const index = resultSet.getColumnIndex('maxSort');
        if (resultSet.isColumnNull(index)) {
          return 0;
        }
        return resultSet.getLong(index);
      }
      return 0;
    } finally {
      resultSet.close();
    }
  }

  static async insert(context: common.UIAbilityContext, record: PhotoRecord): Promise<number> {
    const store = await PhotoDatabase.open(context);
    const values: relationalStore.ValuesBucket = {
      'caption': record.caption,
      'fileName': record.fileName,
      'originalName': record.originalName,
      'mimeType': record.mimeType,
      'width': record.width,
      'height': record.height,
      'sizeBytes': record.sizeBytes,
      'sha256': record.sha256,
      'capturedAt': record.capturedAt,
      'addedAt': record.addedAt,
      'source': record.source,
      'sortIndex': record.sortIndex
    };
    return await store.insert('photos', values);
  }

  static async setCaption(context: common.UIAbilityContext, id: number, caption: string): Promise<void> {
    const store = await PhotoDatabase.open(context);
    const values: relationalStore.ValuesBucket = { 'caption': caption };
    const predicates = new relationalStore.RdbPredicates('photos');
    predicates.equalTo('id', id);
    await store.update(values, predicates);
  }

  static async setSortIndex(context: common.UIAbilityContext, id: number, sortIndex: number): Promise<void> {
    const store = await PhotoDatabase.open(context);
    const values: relationalStore.ValuesBucket = { 'sortIndex': sortIndex };
    const predicates = new relationalStore.RdbPredicates('photos');
    predicates.equalTo('id', id);
    await store.update(values, predicates);
  }

  static async deleteByIds(context: common.UIAbilityContext, ids: number[]): Promise<void> {
    if (ids.length === 0) {
      return;
    }
    const store = await PhotoDatabase.open(context);
    const predicates = new relationalStore.RdbPredicates('photos');
    predicates.in('id', ids);
    await store.delete(predicates);
  }

  static async count(context: common.UIAbilityContext): Promise<number> {
    const store = await PhotoDatabase.open(context);
    const resultSet = await store.querySql('SELECT COUNT(*) AS total FROM photos');
    try {
      if (resultSet.goToNextRow()) {
        return resultSet.getLong(resultSet.getColumnIndex('total'));
      }
      return 0;
    } finally {
      resultSet.close();
    }
  }

  static async totalBytes(context: common.UIAbilityContext): Promise<number> {
    const store = await PhotoDatabase.open(context);
    const resultSet = await store.querySql('SELECT COALESCE(SUM(sizeBytes), 0) AS total FROM photos');
    try {
      if (resultSet.goToNextRow()) {
        return resultSet.getLong(resultSet.getColumnIndex('total'));
      }
      return 0;
    } finally {
      resultSet.close();
    }
  }

  private static readRow(resultSet: relationalStore.ResultSet): PhotoRecord {
    const record: PhotoRecord = {
      id: resultSet.getLong(resultSet.getColumnIndex('id')),
      caption: resultSet.getString(resultSet.getColumnIndex('caption')),
      fileName: resultSet.getString(resultSet.getColumnIndex('fileName')),
      originalName: resultSet.getString(resultSet.getColumnIndex('originalName')),
      mimeType: resultSet.getString(resultSet.getColumnIndex('mimeType')),
      width: resultSet.getLong(resultSet.getColumnIndex('width')),
      height: resultSet.getLong(resultSet.getColumnIndex('height')),
      sizeBytes: resultSet.getLong(resultSet.getColumnIndex('sizeBytes')),
      sha256: resultSet.getString(resultSet.getColumnIndex('sha256')),
      capturedAt: resultSet.getLong(resultSet.getColumnIndex('capturedAt')),
      addedAt: resultSet.getLong(resultSet.getColumnIndex('addedAt')),
      source: resultSet.getString(resultSet.getColumnIndex('source')),
      sortIndex: resultSet.getLong(resultSet.getColumnIndex('sortIndex'))
    };
    return record;
  }
}
