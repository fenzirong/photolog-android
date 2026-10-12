import { abilityAccessCtrl, common, Permissions } from '@kit.AbilityKit';
import { camera } from '@kit.CameraKit';
import { fileIo } from '@kit.CoreFileKit';
import { picker } from '@kit.CoreFileKit';
import { promptAction } from '@kit.ArkUI';
import { PhotoDatabase } from '../data/PhotoDatabase';
import { PhotoRepository } from '../data/PhotoRepository';
import { ShareIntake } from '../data/ShareIntake';
import {
  AppSettings,
  defaultSettings,
  SettingsStore,
  THEME_DARK,
  THEME_LIGHT,
  THEME_SYSTEM
} from '../data/SettingsStore';
import {
  CaptionDocument,
  CaptionFormat,
  ExportNaming,
  ExportOptions,
  ExportScope,
  PhotoRecord
} from '../export/ExportModels';
import { ExportProgress, ExportResult, Exporter } from '../export/Exporter';

/**
 * The ability context, published once by `EntryAbility.onCreate`.
 *
 * Read through a function rather than threaded through constructors: every view needs it, and
 * none of them owns it.
 */
function appContext(): common.UIAbilityContext {
  const context = AppStorage.get<common.UIAbilityContext>('abilityContext');
  if (context === undefined) {
    throw new Error('abilityContext is not initialised; EntryAbility must publish it in onCreate');
  }
  return context;
}

/** Nudges every view to re-read the database after a mutation anywhere in the app. */
function bumpRevision(): void {
  const current = AppStorage.get<number>('libraryRevision');
  AppStorage.setOrCreate('libraryRevision', (current === undefined ? 0 : current) + 1);
}

function toast(message: string): void {
  promptAction.showToast({ message: message, duration: 2500 });
}

function formatBytes(bytes: number): string {
  if (bytes >= 1024 * 1024 * 1024) {
    return `${(bytes / 1024 / 1024 / 1024).toFixed(2)} GB`;
  }
  if (bytes >= 1024 * 1024) {
    return `${(bytes / 1024 / 1024).toFixed(1)} MB`;
  }
  if (bytes >= 1024) {
    return `${Math.round(bytes / 1024)} KB`;
  }
  return `${bytes} B`;
}

function formatDateTime(millis: number): string {
  const d = new Date(millis);
  const pad = (value: number): string => (value < 10 ? `0${value}` : `${value}`);
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())} ${pad(d.getHours())}:${pad(d.getMinutes())}`;
}

function sourceLabel(source: string): string {
  if (source === 'CAMERA') {
    return '拍照';
  }
  if (source === 'SHARE') {
    return '分享';
  }
  return '相册';
}

function indexLabel(index: number): string {
  if (index < 10) {
    return `00${index}`;
  }
  if (index < 100) {
    return `0${index}`;
  }
  return `${index}`;
}

/** The export options a screen should use, taken from the persisted defaults. */
function optionsFrom(settings: AppSettings): ExportOptions {
  const options: ExportOptions = {
    lossless: settings.exportLossless,
    jpegQuality: settings.exportJpegQuality,
    maxLongEdge: settings.exportMaxLongEdge,
    includeCaptions: settings.exportIncludeCaptions,
    captionFormat: settings.exportCaptionFormat,
    numbered: settings.exportNumbered,
    useCaptionAsName: settings.exportNameFromCaption
  };
  return options;
}

// --------------------------------------------------------------------------- //
// Root
// --------------------------------------------------------------------------- //

@Entry
@Component
struct Index {
  @State tabIndex: number = 0;
  @State detailId: number = 0;
  @State detailOpen: boolean = false;

  build() {
    Stack() {
      Tabs({ barPosition: BarPosition.End, index: this.tabIndex }) {
        TabContent() {
          GalleryTab({
            onOpenDetail: (id: number) => {
              this.detailId = id;
              this.detailOpen = true;
            }
          })
        }
        .tabBar('图库')

        TabContent() {
          CaptureTab({
            onOpenDetail: (id: number) => {
              this.detailId = id;
              this.detailOpen = true;
            }
          })
        }
        .tabBar('拍照')

        TabContent() {
          ExportTab()
        }
        .tabBar('导出')

        TabContent() {
          SettingsTab()
        }
        .tabBar('设置')
      }
      .barMode(BarMode.Fixed)
      .onChange((index: number) => {
        this.tabIndex = index;
      })
      .width('100%')
      .height('100%')
    }
    .bindSheet($$this.detailOpen, this.detailSheet(), {
      detents: [SheetSize.LARGE],
      showClose: true
    })
  }

  @Builder
  detailSheet() {
    DetailSheet({
      photoId: this.detailId,
      onClose: () => {
        this.detailOpen = false;
      }
    })
  }
}

// --------------------------------------------------------------------------- //
// Gallery
// --------------------------------------------------------------------------- //

@Component
struct GalleryTab {
  @StorageLink('libraryRevision') @Watch('reload') revision: number = 0;
  @State records: PhotoRecord[] = [];
  @State busy: boolean = false;

  onOpenDetail: (id: number) => void = () => {};

  private context: common.UIAbilityContext = appContext();
  private repository: PhotoRepository = PhotoRepository.of(this.context);

  aboutToAppear(): void {
    ShareIntake.get().onArrive(() => {
      this.importShared();
    });
    this.importShared();
    this.reload();
  }

  reload(): void {
    PhotoDatabase.all(this.context).then((rows: PhotoRecord[]) => {
      this.records = rows;
    });
  }

  /** Drains anything the share sheet handed over, then imports it. */
  private importShared(): void {
    const uris = ShareIntake.get().drain();
    if (uris.length === 0) {
      return;
    }
    this.importUris(uris, 'SHARE');
  }

  /**
   * Imports a batch, one URI at a time.
   *
   * Sequential rather than concurrent: two imports racing would both ask for the next
   * `sortIndex` before either had written, and the second would overwrite the first's position.
   */
  private importUris(uris: string[], source: string): void {
    this.busy = true;
    let added = 0;
    let duplicates = 0;

    const walk = (index: number): void => {
      if (index >= uris.length) {
        this.busy = false;
        let message = `已导入 ${added} 张照片`;
        if (duplicates > 0) {
          message += `，跳过重复 ${duplicates} 张`;
        }
        if (added > 0 || duplicates > 0) {
          toast(message);
        }
        bumpRevision();
        this.reload();
        return;
      }
      this.repository.importUri(uris[index], source)
        .then((record: PhotoRecord | undefined) => {
          if (record === undefined) {
            walk(index + 1);
            return;
          }
          if (record.id !== 0) {
            // A non-zero id means the hash matched an existing row: it is a duplicate.
            duplicates += 1;
            walk(index + 1);
            return;
          }
          PhotoDatabase.maxSortIndex(this.context).then((max: number) => {
            record.sortIndex = max + 1;
            PhotoDatabase.insert(this.context, record).then(() => {
              added += 1;
              walk(index + 1);
            }).catch(() => {
              walk(index + 1);
            });
          });
        })
        .catch(() => {
          walk(index + 1);
        });
    };

    walk(0);
  }

  private pickFromGallery(): void {
    const photoPicker = new picker.PhotoViewPicker();
    photoPicker.select({ maxSelectNumber: 50 })
      .then((result: picker.PhotoSelectResult) => {
        this.importUris(result.photoUris, 'GALLERY');
      })
      .catch(() => {
        // Cancelled picker: nothing to do and nothing to report.
      });
  }

  private move(id: number, delta: number): void {
    const rows = this.records.slice(0);
    let from = -1;
    for (let i = 0; i < rows.length; i++) {
      if (rows[i].id === id) {
        from = i;
        break;
      }
    }
    if (from < 0) {
      return;
    }
    const to = Math.min(Math.max(from + delta, 0), rows.length - 1);
    if (to === from) {
      return;
    }
    const moved = rows.splice(from, 1)[0];
    rows.splice(to, 0, moved);

    // The whole list is renumbered rather than swapping two values: swapping is only correct
    // while every sortIndex is distinct, and one row left at 0 by an interrupted write would
    // turn a swap into a silent no-op.
    let index = 0;
    const writeNext = (): void => {
      if (index >= rows.length) {
        this.reload();
        return;
      }
      const row = rows[index];
      const position = index + 1;
      index += 1;
      PhotoDatabase.setSortIndex(this.context, row.id, position).then(() => {
        writeNext();
      }).catch(() => {
        writeNext();
      });
    };
    writeNext();
  }

  private remove(record: PhotoRecord): void {
    PhotoDatabase.deleteByIds(this.context, [record.id]).then(() => {
      this.repository.deleteFiles([record]);
      toast('已删除');
      bumpRevision();
      this.reload();
    });
  }

  build() {
    Column() {
      Row() {
        Text(`共 ${this.records.length} 张`).fontSize(14).fontColor('#43474E')
        Blank()
        Button('从相册导入')
          .fontSize(14)
          .backgroundColor('#E0E2EC')
          .fontColor('#191C20')
          .onClick(() => {
            this.pickFromGallery();
          })
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 8, bottom: 8 })

      if (this.busy) {
        LoadingProgress().width(32).height(32).margin(8)
      }

      if (this.records.length === 0) {
        Column() {
          Text('图库还是空的').fontSize(18).margin({ bottom: 8 })
          Text('用「拍照」拍一张，或点上方从相册导入；也可以在其他应用里选中图片，用「分享」发送到「图志」。')
            .fontSize(14)
            .fontColor('#43474E')
            .textAlign(TextAlign.Center)
        }
        .padding(32)
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else {
        List({ space: 10 }) {
          ForEach(this.records, (record: PhotoRecord, index: number) => {
            ListItem() {
              PhotoCard({
                record: record,
                position: index + 1,
                path: this.repository.fileFor(record),
                onOpen: () => {
                  this.onOpenDetail(record.id);
                },
                onMoveUp: () => {
                  this.move(record.id, -1);
                },
                onMoveDown: () => {
                  this.move(record.id, 1);
                },
                onDelete: () => {
                  this.remove(record);
                }
              })
            }
          }, (record: PhotoRecord) => `${record.id}`)
        }
        .layoutWeight(1)
        .width('100%')
        .padding({ left: 12, right: 12 })
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#F8F9FC')
  }
}

/**
 * One entry in the library.
 *
 * Reading order is the feature: image → caption → metadata. The caption sits immediately under
 * the photo, which is what makes 「照片下面可以打文字说明」 true of the list and not just of a form.
 */
@Component
struct PhotoCard {
  record: PhotoRecord = {
    id: 0, caption: '', fileName: '', originalName: '', mimeType: '', width: 0, height: 0,
    sizeBytes: 0, sha256: '', capturedAt: 0, addedAt: 0, source: '', sortIndex: 0
  };
  position: number = 1;
  path: string = '';
  onOpen: () => void = () => {};
  onMoveUp: () => void = () => {};
  onMoveDown: () => void = () => {};
  onDelete: () => void = () => {};

  build() {
    Column() {
      Image(this.path)
        .width('100%')
        .aspectRatio(this.record.width > 0 && this.record.height > 0
          ? Math.min(Math.max(this.record.width / this.record.height, 0.35), 3.2)
          : 1)
        .objectFit(ImageFit.Contain)
        .backgroundColor('#FFFFFF')

      Column() {
        Row() {
          Text(indexLabel(this.position))
            .fontSize(11)
            .fontColor('#001B3D')
            .backgroundColor('#D3E3FF')
            .borderRadius(6)
            .padding({ left: 6, right: 6, top: 2, bottom: 2 })
          Text(sourceLabel(this.record.source))
            .fontSize(11)
            .fontColor('#111C27')
            .backgroundColor('#D7E4F2')
            .borderRadius(6)
            .padding({ left: 6, right: 6, top: 2, bottom: 2 })
            .margin({ left: 6 })
          Text(formatDateTime(this.record.capturedAt))
            .fontSize(12)
            .fontColor('#43474E')
            .margin({ left: 8 })
            .layoutWeight(1)
          Text('⋮')
            .fontSize(18)
            .fontColor('#43474E')
            .padding({ left: 8, right: 8 })
            .bindMenu([
              { value: '上移', action: () => this.onMoveUp() },
              { value: '下移', action: () => this.onMoveDown() },
              { value: '编辑文字说明', action: () => this.onOpen() },
              { value: '删除', action: () => this.onDelete() }
            ])
        }
        .width('100%')

        Text(this.record.caption.length > 0 ? this.record.caption : '点这里给这张照片写一行文字说明')
          .fontSize(15)
          .fontColor(this.record.caption.length > 0 ? '#191C20' : '#73777F')
          .fontStyle(this.record.caption.length > 0 ? FontStyle.Normal : FontStyle.Italic)
          .maxLines(4)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
          .margin({ top: 6 })

        Text(`${this.record.width} × ${this.record.height} · ${formatBytes(this.record.sizeBytes)} · ${this.record.mimeType}`)
          .fontSize(11)
          .fontColor('#43474E')
          .width('100%')
          .margin({ top: 4 })
      }
      .padding(12)
      .alignItems(HorizontalAlign.Start)
    }
    .backgroundColor('#E0E2EC')
    .borderRadius(12)
    .clip(true)
    .onClick(() => {
      this.onOpen();
    })
  }
}

// --------------------------------------------------------------------------- //
// Capture
// --------------------------------------------------------------------------- //

@Component
struct CaptureTab {
  @State hasPermission: boolean = false;
  @State cameraError: string = '';
  @State capturing: boolean = false;
  @State lastSavedId: number = 0;
  @State flashMode: number = 0;

  onOpenDetail: (id: number) => void = () => {};

  private context: common.UIAbilityContext = appContext();
  private repository: PhotoRepository = PhotoRepository.of(this.context);
  private surfaceId: string = '';
  private cameraManager: camera.CameraManager | undefined = undefined;
  private photoOutput: camera.PhotoOutput | undefined = undefined;
  private captureSession: camera.PhotoSession | undefined = undefined;
  private controller: XComponentController = new XComponentController();

  aboutToAppear(): void {
    this.requestCamera();
  }

  aboutToDisappear(): void {
    this.releaseCamera();
  }

  private requestCamera(): void {
    const permissions: Permissions[] = ['ohos.permission.CAMERA'];
    const atManager = abilityAccessCtrl.createAtManager();
    atManager.requestPermissionsFromUser(this.context, permissions)
      .then((result: abilityAccessCtrl.PermissionRequestResult) => {
        this.hasPermission = result.authResults.length > 0 && result.authResults[0] === 0;
      })
      .catch(() => {
        this.hasPermission = false;
      });
  }

  private async openCamera(): Promise<void> {
    if (this.surfaceId.length === 0 || this.cameraManager !== undefined) {
      return;
    }
    try {
      const manager = camera.getCameraManager(this.context);
      const devices = manager.getSupportedCameras();
      if (devices.length === 0) {
        this.cameraError = '这台设备上没有可用的摄像头';
        return;
      }
      const device = devices[0];
      const input = manager.createCameraInput(device);
      await input.open();

      const capability = manager.getSupportedOutputCapability(device, camera.SceneMode.NORMAL_PHOTO);
      const previewProfile = CaptureTab.pickProfile(capability.previewProfiles, 1920, 1080);
      const photoProfile = CaptureTab.pickProfile(capability.photoProfiles, 4000, 3000);

      const previewOutput = manager.createPreviewOutput(previewProfile, this.surfaceId);
      this.photoOutput = manager.createPhotoOutput(photoProfile);

      const session = manager.createSession(camera.SceneMode.NORMAL_PHOTO) as camera.PhotoSession;
      session.beginConfig();
      session.addInput(input);
      session.addOutput(previewOutput);
      session.addOutput(this.photoOutput);
      await session.commitConfig();
      await session.start();
      this.captureSession = session;
      this.cameraManager = manager;
    } catch (error) {
      this.cameraError = CaptureTab.describe(error);
    }
  }

  private releaseCamera(): void {
    if (this.captureSession !== undefined) {
      this.captureSession.stop().catch(() => {});
      this.captureSession.release().catch(() => {});
      this.captureSession = undefined;
    }
    this.photoOutput = undefined;
    this.cameraManager = undefined;
  }

  /**
   * Picks the supported profile closest to the requested size.
   *
   * `getSupportedOutputCapability` returns whatever the device offers, which is not a fixed list;
   * asking for an exact size is how a camera screen ends up working on one phone and throwing on
   * the next.
   */
  private static pickProfile(profiles: camera.Profile[], width: number, height: number): camera.Profile {
    let best = profiles[0];
    let bestDistance = Number.MAX_SAFE_INTEGER;
    for (let i = 0; i < profiles.length; i++) {
      const distance = Math.abs(profiles[i].size.width - width) + Math.abs(profiles[i].size.height - height);
      if (distance < bestDistance) {
        bestDistance = distance;
        best = profiles[i];
      }
    }
    return best;
  }

  private capture(): void {
    const output = this.photoOutput;
    if (output === undefined || this.capturing) {
      return;
    }
    this.capturing = true;
    const path = this.repository.newCapturePath();
    const setting: camera.PhotoCaptureSetting = {
      quality: camera.QualityLevel.QUALITY_LEVEL_HIGH,
      rotation: camera.ImageRotation.ROTATION_0,
      flashMode: this.flashMode === 0 ? camera.FlashMode.FLASH_MODE_AUTO
        : (this.flashMode === 1 ? camera.FlashMode.FLASH_MODE_OPEN : camera.FlashMode.FLASH_MODE_CLOSE)
    };
    output.capture(setting).then(() => {
      const record = this.repository.registerCapture(path);
      PhotoDatabase.maxSortIndex(this.context).then((max: number) => {
        record.sortIndex = max + 1;
        PhotoDatabase.insert(this.context, record).then((id: number) => {
          this.lastSavedId = id;
          this.capturing = false;
          toast('已保存到图库');
          bumpRevision();
        }).catch(() => {
          this.capturing = false;
          toast('保存失败');
        });
      });
    }).catch((error: Object) => {
      this.capturing = false;
      toast(`拍照失败：${CaptureTab.describe(error)}`);
    });
  }

  private static describe(error: Object): string {
    if (error instanceof Error) {
      return error.message;
    }
    return `${error}`;
  }

  build() {
    Column() {
      if (!this.hasPermission) {
        Column() {
          Text('需要相机权限才能拍照').fontSize(18).fontColor(Color.White).margin({ bottom: 8 })
          Text('不授权也可以继续用图库导入和「分享到图志」。').fontSize(13).fontColor('#B8BCC4')
          Button('授予权限')
            .margin({ top: 16 })
            .onClick(() => {
              this.requestCamera();
            })
        }
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else if (this.cameraError.length > 0) {
        Column() {
          Text(this.cameraError).fontSize(16).fontColor(Color.White)
          Button('重试')
            .margin({ top: 16 })
            .onClick(() => {
              this.cameraError = '';
              this.releaseCamera();
              this.openCamera();
            })
        }
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else {
        XComponent({ id: 'photolog_preview', type: XComponentType.SURFACE, controller: this.controller })
          .onLoad(() => {
            this.surfaceId = this.controller.getXComponentSurfaceId();
            this.openCamera();
          })
          .onDestroy(() => {
            this.releaseCamera();
          })
          .width('100%')
          .layoutWeight(1)
      }

      Row() {
        Button(this.flashMode === 0 ? '闪光灯 自动' : (this.flashMode === 1 ? '闪光灯 开' : '闪光灯 关'))
          .fontSize(13)
          .backgroundColor('#E0E2EC')
          .fontColor('#191C20')
          .onClick(() => {
            this.flashMode = (this.flashMode + 1) % 3;
          })

        Button(this.capturing ? '保存中…' : '拍照')
          .width(96)
          .height(56)
          .fontSize(16)
          .enabled(!this.capturing)
          .onClick(() => {
            this.capture();
          })

        Button(this.lastSavedId > 0 ? '写说明' : '—')
          .fontSize(13)
          .backgroundColor('#E0E2EC')
          .fontColor('#191C20')
          .enabled(this.lastSavedId > 0)
          .onClick(() => {
            this.onOpenDetail(this.lastSavedId);
          })
      }
      .width('100%')
      .justifyContent(FlexAlign.SpaceEvenly)
      .padding(16)
      .backgroundColor('#FFFFFF')

      Text('照片按原样保存，不做二次压缩。拍完在图库里给它写一行文字说明，导出时可以按顺序连着说明一起带走。')
        .fontSize(11)
        .fontColor('#43474E')
        .padding({ left: 16, right: 16, bottom: 12 })
        .backgroundColor('#FFFFFF')
        .width('100%')
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#000000')
  }
}

// --------------------------------------------------------------------------- //
// Detail
// --------------------------------------------------------------------------- //

@Component
struct DetailSheet {
  photoId: number = 0;
  onClose: () => void = () => {};

  @State record: PhotoRecord | undefined = undefined;
  @State caption: string = '';
  @State settings: AppSettings = defaultSettings();

  private context: common.UIAbilityContext = appContext();
  private repository: PhotoRepository = PhotoRepository.of(this.context);

  aboutToAppear(): void {
    PhotoDatabase.findOne(this.context, this.photoId).then((row: PhotoRecord | undefined) => {
      this.record = row;
      if (row !== undefined) {
        this.caption = row.caption;
      }
    });
    SettingsStore.of(this.context).load().then((loaded: AppSettings) => {
      this.settings = loaded;
    });
  }

  private saveCaption(): void {
    const row = this.record;
    if (row === undefined || row.caption === this.caption) {
      return;
    }
    PhotoDatabase.setCaption(this.context, row.id, this.caption).then(() => {
      bumpRevision();
    });
  }

  private exportThis(): void {
    const row = this.record;
    if (row === undefined) {
      return;
    }
    new Exporter(this.context).exportSingle(row, optionsFrom(this.settings))
      .then((result: ExportResult) => {
        toast(result.message);
      });
  }

  private remove(): void {
    const row = this.record;
    if (row === undefined) {
      return;
    }
    PhotoDatabase.deleteByIds(this.context, [row.id]).then(() => {
      this.repository.deleteFiles([row]);
      bumpRevision();
      toast('已删除');
      this.onClose();
    });
  }

  build() {
    Column() {
      if (this.record === undefined) {
        Text('这张照片已经不在图库里了').margin(24)
      } else {
        Scroll() {
          Column() {
            Image(this.repository.fileFor(this.record))
              .width('100%')
              .aspectRatio(this.record.width > 0 && this.record.height > 0
                ? Math.min(Math.max(this.record.width / this.record.height, 0.35), 3.2)
                : 1)
              .objectFit(ImageFit.Contain)
              .backgroundColor('#E0E2EC')
              .borderRadius(12)

            TextArea({ text: this.caption, placeholder: '这是什么时候、在哪、拍的什么？' })
              .height(110)
              .width('100%')
              .margin({ top: 14 })
              .onChange((value: string) => {
                this.caption = value;
              })
              .onBlur(() => {
                this.saveCaption();
              })

            Text('离开输入框时自动保存；导出时这段文字会跟在对应图片下面，按顺序一起写进说明文件。')
              .fontSize(12)
              .fontColor('#43474E')
              .width('100%')
              .margin({ top: 6 })

            Divider().margin({ top: 14, bottom: 10 })

            Column() {
              DetailRow({
                label: '文件名',
                value: this.record.originalName.length > 0 ? this.record.originalName : this.record.fileName
              })
              DetailRow({
                label: '尺寸',
                value: this.record.width > 0 ? `${this.record.width} × ${this.record.height}` : '未知'
              })
              DetailRow({ label: '大小', value: formatBytes(this.record.sizeBytes) })
              DetailRow({ label: '格式', value: this.record.mimeType })
              DetailRow({ label: '拍摄时间', value: formatDateTime(this.record.capturedAt) })
              DetailRow({ label: '导入方式', value: sourceLabel(this.record.source) })
              DetailRow({ label: '顺序', value: `${this.record.sortIndex}（导出时按此顺序）` })
            }
            .width('100%')

            Row() {
              Button('无损导出这张')
                .fontSize(14)
                .layoutWeight(1)
                .onClick(() => {
                  this.exportThis();
                })
              Button('删除')
                .fontSize(14)
                .layoutWeight(1)
                .backgroundColor('#F5DADF')
                .fontColor('#8C1D2C')
                .margin({ left: 10 })
                .onClick(() => {
                  this.remove();
                })
            }
            .width('100%')
            .margin({ top: 16, bottom: 24 })
          }
          .padding({ left: 16, right: 16 })
        }
        .layoutWeight(1)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#F8F9FC')
  }
}

@Component
struct DetailRow {
  label: string = '';
  value: string = '';

  build() {
    Row() {
      Text(this.label).fontSize(12).fontColor('#43474E').width(76)
      Text(this.value).fontSize(13).layoutWeight(1)
    }
    .width('100%')
    .margin({ bottom: 4 })
  }
}

// --------------------------------------------------------------------------- //
// Export
// --------------------------------------------------------------------------- //

@Component
struct ExportTab {
  @StorageLink('libraryRevision') @Watch('reload') revision: number = 0;
  @State records: PhotoRecord[] = [];
  @State settings: AppSettings = defaultSettings();
  @State scope: ExportScope = 'all';
  @State progress: ExportProgress | undefined = undefined;

  private context: common.UIAbilityContext = appContext();

  aboutToAppear(): void {
    this.reload();
    SettingsStore.of(this.context).load().then((loaded: AppSettings) => {
      this.settings = loaded;
    });
  }

  reload(): void {
    PhotoDatabase.all(this.context).then((rows: PhotoRecord[]) => {
      this.records = rows;
    });
  }

  private planned(): number {
    return ExportNaming.plan(this.records, this.scope, optionsFrom(this.settings)).length;
  }

  private run(what: string): void {
    const exporter = new Exporter(this.context);
    const onProgress = (value: ExportProgress): void => {
      this.progress = value;
    };
    const options = optionsFrom(this.settings);
    let task: Promise<ExportResult>;
    if (what === 'zip') {
      task = exporter.exportZip(this.records, this.scope, options, onProgress);
    } else if (what === 'loose') {
      task = exporter.exportLoose(this.records, this.scope, options, onProgress);
    } else {
      task = exporter.exportCaptionsOnly(this.records, this.scope, options);
    }
    task.then((result: ExportResult) => {
      this.progress = undefined;
      toast(result.message);
    }).catch((error: Object) => {
      this.progress = undefined;
      toast(`导出失败：${error}`);
    });
  }

  build() {
    Scroll() {
      Column() {
        Text('导出范围').fontSize(16).fontColor('#1D4E89').width('100%').margin({ top: 8, bottom: 6 })
        Row() {
          this.scopeChip('all', '全部照片')
          this.scopeChip('withCaption', '仅有文字说明')
          this.scopeChip('recent', '最近 20 张')
        }
        .width('100%')

        Text(`当前将导出 ${this.planned()} 张，顺序就是「图库」里的顺序，可以在图库里上移下移调整。`)
          .fontSize(12)
          .fontColor('#43474E')
          .width('100%')
          .margin({ top: 8 })

        if (this.progress !== undefined) {
          Progress({
            value: this.progress.done,
            total: Math.max(this.progress.total, 1),
            type: ProgressType.Linear
          })
            .width('100%')
            .margin({ top: 12 })
          Text(`${this.progress.done} / ${this.progress.total} · ${this.progress.current}`)
            .fontSize(12)
            .fontColor('#43474E')
            .width('100%')
        }

        Divider().margin({ top: 14, bottom: 12 })

        Text('图片质量').fontSize(16).fontColor('#1D4E89').width('100%')
        Row() {
          Text('无损导出（推荐）').fontSize(15).layoutWeight(1)
          Toggle({ type: ToggleType.Switch, isOn: this.settings.exportLossless })
            .onChange((isOn: boolean) => {
              this.settings.exportLossless = isOn;
              SettingsStore.of(this.context).saveBoolean('exportLossless', isOn);
            })
        }
        .width('100%')
        .margin({ top: 6 })

        Text(this.settings.exportLossless
          ? '原样复制文件字节，不重新编码，EXIF、色彩信息和画质 100% 保留；文件大小与原图相同。'
          : '会解码后重新编码为 JPEG，画质有损但文件更小。')
          .fontSize(12)
          .fontColor('#43474E')
          .width('100%')
          .margin({ top: 4 })

        Divider().margin({ top: 14, bottom: 12 })

        Text('文字说明').fontSize(16).fontColor('#1D4E89').width('100%')
        Row() {
          Text('导出图片下方的文字说明').fontSize(15).layoutWeight(1)
          Toggle({ type: ToggleType.Switch, isOn: this.settings.exportIncludeCaptions })
            .onChange((isOn: boolean) => {
              this.settings.exportIncludeCaptions = isOn;
              SettingsStore.of(this.context).saveBoolean('exportIncludeCaptions', isOn);
            })
        }
        .width('100%')
        .margin({ top: 6 })

        Row() {
          this.formatChip('markdown', 'Markdown')
          this.formatChip('html', 'HTML 网页')
          this.formatChip('text', '纯文本')
        }
        .width('100%')
        .margin({ top: 8 })

        Text('说明文件的每一段都是「一张图 + 紧跟它下面的文字」，顺序与图库一致。')
          .fontSize(12)
          .fontColor('#43474E')
          .width('100%')
          .margin({ top: 6 })

        Divider().margin({ top: 14, bottom: 12 })

        Text('文件命名').fontSize(16).fontColor('#1D4E89').width('100%')
        Row() {
          this.nameChip(true, '用图片下方的说明文字')
          this.nameChip(false, '用原文件名')
        }
        .width('100%')
        .margin({ top: 6 })

        Row() {
          Text('加序号前缀（001_、002_…）').fontSize(15).layoutWeight(1)
          Toggle({ type: ToggleType.Switch, isOn: this.settings.exportNumbered })
            .onChange((isOn: boolean) => {
              this.settings.exportNumbered = isOn;
              SettingsStore.of(this.context).saveBoolean('exportNumbered', isOn);
            })
        }
        .width('100%')
        .margin({ top: 8 })

        Divider().margin({ top: 14, bottom: 12 })

        Text('输出方式').fontSize(16).fontColor('#1D4E89').width('100%')
        Button('打包为 ZIP（图片 + 说明文件）')
          .width('100%')
          .margin({ top: 8 })
          .enabled(this.planned() > 0)
          .onClick(() => {
            this.run('zip');
          })
        Button('导出到文件夹（图片与说明分开放）')
          .width('100%')
          .margin({ top: 8 })
          .backgroundColor('#E0E2EC')
          .fontColor('#191C20')
          .enabled(this.planned() > 0)
          .onClick(() => {
            this.run('loose');
          })
        Button(`只导出说明文件（${CaptionDocument.fileName(this.settings.exportCaptionFormat)}）`)
          .width('100%')
          .margin({ top: 8 })
          .backgroundColor('#E0E2EC')
          .fontColor('#191C20')
          .enabled(this.planned() > 0)
          .onClick(() => {
            this.run('captions');
          })

        Text('ZIP 适合整包发给别人；文件夹适合自己归档，图片可以直接被其它应用打开。')
          .fontSize(12)
          .fontColor('#43474E')
          .width('100%')
          .margin({ top: 8, bottom: 32 })
      }
      .padding({ left: 16, right: 16 })
      .width('100%')
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#F8F9FC')
  }

  @Builder
  scopeChip(value: ExportScope, label: string) {
    Text(label)
      .fontSize(13)
      .padding({ left: 10, right: 10, top: 6, bottom: 6 })
      .borderRadius(16)
      .backgroundColor(this.scope === value ? '#1D4E89' : '#E0E2EC')
      .fontColor(this.scope === value ? Color.White : '#191C20')
      .margin({ right: 8 })
      .onClick(() => {
        this.scope = value;
      })
  }

  @Builder
  formatChip(value: string, label: string) {
    Text(label)
      .fontSize(13)
      .padding({ left: 10, right: 10, top: 6, bottom: 6 })
      .borderRadius(16)
      .backgroundColor(this.settings.exportCaptionFormat === value ? '#1D4E89' : '#E0E2EC')
      .fontColor(this.settings.exportCaptionFormat === value ? Color.White : '#191C20')
      .margin({ right: 8 })
      .onClick(() => {
        const format = value === 'html' ? 'html' : (value === 'text' ? 'text' : 'markdown');
        this.settings.exportCaptionFormat = format;
        SettingsStore.of(this.context).saveString('exportCaptionFormat', value);
      })
  }

  @Builder
  nameChip(value: boolean, label: string) {
    Text(label)
      .fontSize(13)
      .padding({ left: 10, right: 10, top: 6, bottom: 6 })
      .borderRadius(16)
      .backgroundColor(this.settings.exportNameFromCaption === value ? '#1D4E89' : '#E0E2EC')
      .fontColor(this.settings.exportNameFromCaption === value ? Color.White : '#191C20')
      .margin({ right: 8 })
      .onClick(() => {
        this.settings.exportNameFromCaption = value;
        SettingsStore.of(this.context).saveBoolean('exportNameFromCaption', value);
      })
  }
}

// --------------------------------------------------------------------------- //
// Settings
// --------------------------------------------------------------------------- //

@Component
struct SettingsTab {
  @StorageLink('libraryRevision') @Watch('reload') revision: number = 0;
  @State settings: AppSettings = defaultSettings();
  @State count: number = 0;
  @State totalBytes: number = 0;

  private context: common.UIAbilityContext = appContext();

  aboutToAppear(): void {
    this.reload();
    SettingsStore.of(this.context).load().then((loaded: AppSettings) => {
      this.settings = loaded;
    });
  }

  reload(): void {
    PhotoDatabase.count(this.context).then((value: number) => {
      this.count = value;
    });
    PhotoDatabase.totalBytes(this.context).then((value: number) => {
      this.totalBytes = value;
    });
  }

  build() {
    Scroll() {
      Column() {
        Text('外观').fontSize(16).fontColor('#1D4E89').width('100%').margin({ top: 8, bottom: 6 })
        Row() {
          this.themeChip(THEME_SYSTEM, '跟随系统')
          this.themeChip(THEME_LIGHT, '浅色')
          this.themeChip(THEME_DARK, '深色')
        }
        .width('100%')

        Divider().margin({ top: 16, bottom: 12 })

        Text('存储').fontSize(16).fontColor('#1D4E89').width('100%')
        Text(`共 ${this.count} 张照片，占用 ${formatBytes(this.totalBytes)}。原图保存在应用私有目录，卸载应用会一并删除。`)
          .fontSize(12)
          .fontColor('#43474E')
          .width('100%')
          .margin({ top: 6 })

        Divider().margin({ top: 16, bottom: 12 })

        Text('关于').fontSize(16).fontColor('#1D4E89').width('100%')
        Text('图志把「照片 + 它下面的一行文字」当作一个整体：拍下或收下的图片原样保存，说明写在图片下方，导出时可以按当前顺序把图片和说明一起带走。')
          .fontSize(12).fontColor('#43474E').width('100%').margin({ top: 6 })
        Text('接收分享：在相册、文件管理器或聊天应用里选中图片，用「分享」发送到「图志」即可入库；支持一次分享多张。')
          .fontSize(12).fontColor('#43474E').width('100%').margin({ top: 6 })
        Text('无损导出：导出时默认按字节复制原始文件，不重新编码，EXIF 与画质完全保留。')
          .fontSize(12).fontColor('#43474E').width('100%').margin({ top: 6 })
        Text('隐私：应用只申请相机权限。相册导入使用系统照片选择器，导出走系统文件选择器，由你指定写入位置。')
          .fontSize(12).fontColor('#43474E').width('100%').margin({ top: 6 })
        Text('版本 0.0.1（HarmonyOS NEXT 版）')
          .fontSize(11).fontColor('#43474E').width('100%').margin({ top: 12, bottom: 32 })
      }
      .padding({ left: 16, right: 16 })
      .width('100%')
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#F8F9FC')
  }

  @Builder
  themeChip(value: string, label: string) {
    Text(label)
      .fontSize(13)
      .padding({ left: 10, right: 10, top: 6, bottom: 6 })
      .borderRadius(16)
      .backgroundColor(this.settings.themeMode === value ? '#1D4E89' : '#E0E2EC')
      .fontColor(this.settings.themeMode === value ? Color.White : '#191C20')
      .margin({ right: 8 })
      .onClick(() => {
        this.settings.themeMode = value;
        SettingsStore.of(this.context).saveString('themeMode', value);
      })
  }
}
