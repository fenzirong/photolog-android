import { AbilityConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { ShareIntake } from '../data/ShareIntake';

const DOMAIN: number = 0x0000;
const TAG: string = 'PhotoLog';

/**
 * Pulls the shared image URIs out of the `Want` that launched or re-entered this ability.
 *
 * Two places carry them, and a sender uses one or the other:
 *
 * - `want.uri` — a single shared item.
 * - `want.parameters['ability.params.stream']` — the list form, used when more than one file was
 *   shared. It arrives as an `Array<string>` of `file://` URIs.
 *
 * Both are read because reading only `want.uri` is the classic reason "sharing into this app does
 * nothing when I select several photos".
 */
export function collectSharedUris(want: Want): string[] {
  const uris: string[] = [];

  if (typeof want.uri === 'string' && want.uri.length > 0) {
    uris.push(want.uri);
  }

  const parameters = want.parameters;
  if (parameters !== undefined) {
    const raw: Object | undefined = parameters['ability.params.stream'];
    if (raw !== undefined && Array.isArray(raw)) {
      const list = raw as string[];
      for (let i = 0; i < list.length; i++) {
        const item = list[i];
        if (typeof item === 'string' && item.length > 0) {
          uris.push(item);
        }
      }
    }
  }

  return uris;
}

export default class EntryAbility extends UIAbility {

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    // The pages read the ability context from AppStorage rather than threading it through every
    // constructor; this is the single place it is published.
    AppStorage.setOrCreate('abilityContext', this.context);
    AppStorage.setOrCreate('libraryRevision', 0);

    const shared = collectSharedUris(want);
    hilog.info(DOMAIN, TAG, 'onCreate with %{public}d shared uri(s)', shared.length);
    ShareIntake.get().submit(shared);
  }

  /**
   * A second share while the app is already running.
   *
   * The ability is not recreated, so without this the new image would never reach the library.
   */
  onNewWant(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    const shared = collectSharedUris(want);
    hilog.info(DOMAIN, TAG, 'onNewWant with %{public}d shared uri(s)', shared.length);
    ShareIntake.get().submit(shared);
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, TAG, 'loadContent failed: %{public}s', JSON.stringify(err));
      }
    });
  }

  onDestroy(): void {
    hilog.info(DOMAIN, TAG, 'onDestroy');
  }
}
