import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { CaptionFormat } from '../export/ExportModels';

/**
 * Everything the user can change, in one immutable snapshot.
 *
 * The field names mirror the Android `AppSettings` one for one, so the two builds behave the
 * same way for the same choices — including the defaults, which are the part users notice.
 */
export interface AppSettings {
  themeMode: string;
  exportLossless: boolean;
  exportIncludeCaptions: boolean;
  exportCaptionFormat: CaptionFormat;
  exportNumbered: boolean;
  exportNameFromCaption: boolean;
  exportJpegQuality: number;
  exportMaxLongEdge: number;
}

export const THEME_SYSTEM: string = 'system';
export const THEME_LIGHT: string = 'light';
export const THEME_DARK: string = 'dark';

export function defaultSettings(): AppSettings {
  return {
    themeMode: THEME_SYSTEM,
    exportLossless: true,
    exportIncludeCaptions: true,
    exportCaptionFormat: 'markdown',
    exportNumbered: true,
    exportNameFromCaption: true,
    exportJpegQuality: 95,
    exportMaxLongEdge: 4096
  };
}

const STORE_NAME: string = 'photolog_settings';

/**
 * Persisted user preferences.
 *
 * Defaults are applied on read rather than written on first launch, so an app that is never
 * configured never has to touch disk — and so that adding a setting later needs no migration.
 */
export class SettingsStore {
  private static instance: SettingsStore | undefined = undefined;

  private context: common.UIAbilityContext;
  private store: preferences.Preferences | undefined = undefined;

  private constructor(context: common.UIAbilityContext) {
    this.context = context;
  }

  static of(context: common.UIAbilityContext): SettingsStore {
    if (SettingsStore.instance === undefined) {
      SettingsStore.instance = new SettingsStore(context);
    }
    return SettingsStore.instance;
  }

  async load(): Promise<AppSettings> {
    const store = await this.open();
    const defaults = defaultSettings();
    return {
      themeMode: await this.readString(store, 'themeMode', defaults.themeMode),
      exportLossless: await this.readBoolean(store, 'exportLossless', defaults.exportLossless),
      exportIncludeCaptions: await this.readBoolean(store, 'exportIncludeCaptions', defaults.exportIncludeCaptions),
      exportCaptionFormat: SettingsStore.asFormat(
        await this.readString(store, 'exportCaptionFormat', defaults.exportCaptionFormat)
      ),
      exportNumbered: await this.readBoolean(store, 'exportNumbered', defaults.exportNumbered),
      exportNameFromCaption: await this.readBoolean(store, 'exportNameFromCaption', defaults.exportNameFromCaption),
      exportJpegQuality: await this.readNumber(store, 'exportJpegQuality', defaults.exportJpegQuality),
      exportMaxLongEdge: await this.readNumber(store, 'exportMaxLongEdge', defaults.exportMaxLongEdge)
    };
  }

  async saveString(key: string, value: string): Promise<void> {
    const store = await this.open();
    await store.put(key, value);
    await store.flush();
  }

  async saveBoolean(key: string, value: boolean): Promise<void> {
    const store = await this.open();
    await store.put(key, value);
    await store.flush();
  }

  async saveNumber(key: string, value: number): Promise<void> {
    const store = await this.open();
    await store.put(key, value);
    await store.flush();
  }

  private async open(): Promise<preferences.Preferences> {
    if (this.store === undefined) {
      this.store = await preferences.getPreferences(this.context, STORE_NAME);
    }
    return this.store;
  }

  private async readString(store: preferences.Preferences, key: string, fallback: string): Promise<string> {
    const value = await store.get(key, fallback);
    return typeof value === 'string' ? value : fallback;
  }

  private async readBoolean(store: preferences.Preferences, key: string, fallback: boolean): Promise<boolean> {
    const value = await store.get(key, fallback);
    return typeof value === 'boolean' ? value : fallback;
  }

  private async readNumber(store: preferences.Preferences, key: string, fallback: number): Promise<number> {
    const value = await store.get(key, fallback);
    return typeof value === 'number' ? value : fallback;
  }

  /** A stored format string that no longer names a format falls back rather than failing. */
  private static asFormat(value: string): CaptionFormat {
    if (value === 'html' || value === 'text' || value === 'markdown') {
      return value;
    }
    return 'markdown';
  }
}
