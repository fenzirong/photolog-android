/**
 * Images handed over by another app through the system share sheet.
 *
 * A queue rather than a single slot because a share can arrive while the app is still starting:
 * `EntryAbility.onCreate` runs before the first page is composed, so the producer always runs
 * first and the consumer has to be able to drain everything that piled up.
 */
export class ShareIntake {
  private static instance: ShareIntake | undefined = undefined;

  private pending: string[] = [];
  private listener: (() => void) | undefined = undefined;

  static get(): ShareIntake {
    if (ShareIntake.instance === undefined) {
      ShareIntake.instance = new ShareIntake();
    }
    return ShareIntake.instance;
  }

  /** Called from the ability. De-duplicates: senders routinely repeat the same URI. */
  submit(uris: string[]): void {
    let added = false;
    for (let i = 0; i < uris.length; i++) {
      if (uris[i].length > 0 && this.pending.indexOf(uris[i]) < 0) {
        this.pending.push(uris[i]);
        added = true;
      }
    }
    if (added && this.listener !== undefined) {
      this.listener();
    }
  }

  /** Takes everything queued so far, leaving the queue empty. */
  drain(): string[] {
    const taken = this.pending;
    this.pending = [];
    return taken;
  }

  /**
   * Wakes the UI when a share arrives while it is already on screen.
   *
   * A share that starts the app from cold does not need this — the page reads the queue in
   * `aboutToAppear`. A share delivered to an already-running app does, and without it the image
   * would sit in the queue until something else happened to refresh the page.
   */
  onArrive(listener: () => void): void {
    this.listener = listener;
  }
}
