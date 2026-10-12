# 图志 · PhotoLog

把「照片 + 它下面那一行文字」当成一个整体来管理的安卓应用。

拍下或收下的图片原样保存、不做二次压缩；说明写在图片正下方；导出时按当前顺序把图片和说明一起带走——包括一份「一张图紧跟它自己的说明」的说明文件。

界面体系参考同目录下的 `biolit-android`（生物论文文献与动态抓取安卓应用）：Compose + Material 3 + 动态取色、底部四项 `NavigationBar`、每个页面自持 `Scaffold`、Room 作为唯一数据源、DataStore 存设置。

---

## 两个平台

| 平台 | 目录 | 状态 |
|---|---|---|
| Android（7.0+） | 仓库根目录 | 完整闭环：编译、签名、30 项单测、CI 发布、产物独立校验 |
| **HarmonyOS NEXT（纯血鸿蒙，API 12）** | [`harmonyos/`](harmonyos/README.md) | **源码交付。未编译、未在真机验证**——原因见 [harmonyos/README.md](harmonyos/README.md) |

鸿蒙版是另一套技术栈（ArkTS + ArkUI + RDB + CameraKit，构建用 hvigor），不是 Android 版的换壳。两版的**导出命名规则、说明文档格式、ZIP 条目命名与中文处理逐条对齐**，同一批照片在两端导出的结果应当一致。

鸿蒙版唯一能在这台机器上真跑验证的是导出逻辑（纯 TypeScript，不依赖鸿蒙 API）：

```bash
node harmonyos/tools/verify-export.mjs   # 67 passed, 0 failed
```

它跑的是 `harmonyos/entry/src/main/ets/export/` 下的 `.ets` 源码本身，并用 **Windows 自带的 `Expand-Archive`** 做真实解压往返，确认中文条目名 `images/001_清晨的雾.jpg` 原样还原。

---

## 一、需求对照

| 需求 | 实现位置 | 说明 |
|---|---|---|
| UI 参考 `biolit-android` | `ui/Theme.kt`、`ui/PhotoLogRoot.kt`、各 `*Screen.kt` | 同一套 Compose/Material3 体系：动态取色（Android 12+ 回落自定义配色）、底部 4 项导航、每屏独立 `Scaffold`、卡片式列表、空状态带行动指引、`enableEdgeToEdge` + `SplashScreen` |
| 存入拍照 | `ui/CaptureScreen.kt` + `data/PhotoRepository.registerCapture` | CameraX `ImageCapture` 直接写入应用私有目录，**不经过 Bitmap**，落盘的就是传感器产出的原始 JPEG；支持闪光灯三态、前后摄切换 |
| 照片下打文字说明 | `ui/Components.kt` 的 `PhotoCard`、`ui/DetailScreen.kt` | 列表里说明就渲染在图片正下方（空则显示斜体占位提示）；详情页多行输入框，输入后 400ms 防抖自动写库，不需要点保存 |
| 支持安卓图片分享进来 | `AndroidManifest.xml` 的三个 intent-filter + `MainActivity.SharedImages` + `data/ShareIntake.kt` | 接收 `ACTION_SEND`、`ACTION_SEND_MULTIPLE`、`ACTION_VIEW`（均 `image/*`），并额外读 `clipData`；导入在导航根节点消费，任何标签页、冷启动都能落库 |
| 图片可选择无损导出 | `export/Exporter.kt` 的 `writeImage` | 无损 = 原始文件**按字节流复制**，不重新编码，EXIF/色彩/画质完全保留；也可切换为「压缩 JPEG」并选质量与最长边 |
| 按顺序导出图片 + 图下说明 | `export/ExportModels.kt` 的 `ExportNaming` + `CaptionDocument` | 导出顺序 = 图库顺序（`sortIndex` 密集 1..n，可手动上移下移）；说明文件每段都是「图片路径 → 紧跟它下面的文字」；支持 Markdown / HTML / 纯文本，输出为 ZIP 或文件夹 |
| 导出图片文件名 = 图片下方的说明文字 | `ExportNaming.baseName` + `sanitize` | 有说明就以说明命名（`001_清晨的雾.jpg`），没说明回退到原文件名；非法字符替换、超长截断、重名加 `_2`；可在导出页/设置页切回「用原文件名」 |
| 说明文字支持中文 | `ExportModels.kt` + `Exporter.kt` | 全链路 UTF-8，并专门处理三处会踩的中文坑：ZIP 条目名 EFS 标志位、`captions.txt` 的 BOM、截断不切代理对（见「关键设计取舍」） |

---

## 二、功能清单

**图库**
- 列表按 `sortIndex` 展示，图片按各自真实宽高比排版（不裁切、不统一高度）
- 每张卡片：序号徽章、来源徽章（拍照 / 相册 / 分享）、拍摄时间、说明文字、尺寸·体积·格式
- 卡片菜单：上移 / 下移（仅手动顺序下可用）、写或编辑说明、无损导出这张、删除
- 顶栏：从相册导入（系统照片选择器，可多选至 50 张）、切换排序（手动顺序 / 按拍摄时间 / 按导入时间）
- 右下角 `ExtendedFloatingActionButton` 直达拍照

**拍照**
- 相机权限按需申请；拒绝后仍可正常使用图库导入与分享接收
- 拍完即入库，并在下方出现缩略图 + 「写说明」直达详情页
- 无摄像头 / 启动失败给出可重试的错误态，不静默黑屏

**详情**
- 大图（`ContentScale.Fit`，不裁切）
- 说明输入框，防抖自动保存
- 元信息：文件名、尺寸、体积、格式、拍摄时间（EXIF `DateTimeOriginal` 优先）、导入方式、顺序、SHA-256 前 16 位
- 顶栏：上移 / 下移 / 无损导出 / 删除（二次确认）

**导出**
- 范围：全部 / 仅有文字说明的 / 最近 20 张
- 质量：无损（默认）或压缩 JPEG（质量 80/90/95/100 × 最长边 原始/4096/2048/1280）
- 说明：是否包含、格式三选一、**可预览说明文件前 40 行**
- 命名：文件名来源（**图片下方的说明文字** / 原文件名）+ 是否加 `001_` 序号前缀
- 输出：打包为 ZIP（单文件，含 `images/` + 说明文件）／导出到文件夹（图片与说明分开放）／只导出说明文件
- 全程 `LinearProgressIndicator` + 「已完成/总数 · 当前文件名」

**设置**
- 外观：跟随系统 / 浅色 / 深色
- 导出默认值：无损、包含说明、序号前缀、**文件名来源（说明文字 / 原文件名）**、说明格式、JPEG 质量、最长边
- 存储：照片数与占用体积、按拍摄时间重排、清空图库（二次确认）
- 关于：功能与隐私说明

---

## 三、数据与文件布局

```
filesDir/
  originals/                     ← 原图，只写一次、只读导出
    c_20261012_093100_123.jpg    ← 拍照（c_）
    g_20261012_093155_456.jpg    ← 导入 / 分享（g_）
databases/
  photolog.db                    ← Room：photos 表
datastore/
  photolog_settings.preferences_pb
```

`photos` 表字段：

| 列 | 类型 | 含义 |
|---|---|---|
| `id` | INTEGER PK AUTOINCREMENT | |
| `caption` | TEXT | 图片下方的文字说明，空串而非 NULL |
| `fileName` | TEXT | `originals/` 下的文件名 |
| `originalName` | TEXT? | 来源侧显示名，用于导出命名 |
| `mimeType` | TEXT | 按「字节嗅探 > ContentResolver > 文件名后缀」优先级判定 |
| `width` / `height` | INTEGER | 仅解码头信息取得，0 表示无法解码 |
| `sizeBytes` | INTEGER | 字节数 |
| `sha256` | TEXT | 去重键：同一张图重复分享/导入不会产生第二条记录 |
| `capturedAt` | INTEGER | epoch 毫秒，EXIF `DateTimeOriginal` 优先，否则取导入时刻 |
| `addedAt` | INTEGER | epoch 毫秒，「最近 20 张」依据 |
| `source` | TEXT | `CAMERA` / `GALLERY` / `SHARE`（存枚举名，不存序号） |
| `sortIndex` | INTEGER | 密集 1..n 顺序，每次重排整体重写 |

索引：`sortIndex`、`capturedAt`、`sha256`。

---

## 四、关键设计取舍

**为什么原图必须原样留着。** 无损导出的定义就是「和目标文件逐字节相同」。任何走一遍 JPEG 编码器的路径，即使质量给到 100 也已经有损——所以拍摄路径直接让 `ImageCapture` 写文件、导入路径整体流式落盘，全程不构造 `Bitmap`。导出时的无损分支只做一次 `inputStream().copyTo()`。

**为什么去重按 SHA-256 而不是文件名。** 同一张图从相册导入一次、再从聊天软件分享进来一次，文件名多半不同而内容完全相同。先算哈希再决定是否落盘，重复导入的代价只是一次哈希加一次临时文件删除。

**为什么 `sortIndex` 是密集序号。** 用间隙法（10、20、30…）能减少写入，但一次中断写入留下的 0 值会让「交换两个相邻值」变成静默无效操作。照片列表规模有限，整体重编号换来「下标即位置」这条不变量，划算。

**为什么分享导入放在导航根节点。** 从分享面板冷启动时，Activity 是被那个 Intent 创建出来的；此时还没有任何页面被组合。导入写在某个页面的 ViewModel 里，会漏掉「分享进来时用户不在那一页」的全部情况。`ShareIntake` 用 `Channel` 而非 `StateFlow`：分享是事件不是状态，状态容器要么重复消费、要么在收集者就位前丢失。

**为什么 HTML 说明文件要转义。** 说明是用户自由文本。不转义的话，一句 `<script>` 就能让导出的 HTML 在别人机器上执行——导出文件是要发出去的。

### 中文支持：三处真的会坏的地方

中文本身不需要特殊照顾——Kotlin `String` 是 UTF-16，SQLite TEXT 列与 `toByteArray(Charsets.UTF_8)` 全程无损。但下面三处是中文会**真的**出问题的地方，都做了处理并有测试兜着：

**1. ZIP 里的中文文件名。** ZIP 条目名默认按系统代码页解释，中文名在 Windows 上解压就成乱码。`ZipOutputStream` 用 UTF-8 编码名并把通用标志位 bit 11（EFS）置位后，解压器才会按 UTF-8 读。这是「导出给别人」最容易翻车的一环，所以有一条测试直接去读本地文件头的标志位，而不是只看 `ZipInputStream` 能不能读回来（后者在两种情况下都能读回来，验不出问题）。

**2. `captions.txt` 的编码声明。** `.txt` 是三种格式里唯一没法在文件内声明编码的。不带 BOM 时，中文说明在 Windows 记事本打开、或双击进 Excel，就是经典的「中文乱码」。所以纯文本格式前置 UTF-8 BOM（`EF BB BF`）。Markdown 和 HTML 都能自己声明编码，就不加——加了只会在每次 diff 里多一个看不见的字符。

**3. 截断不能切在代理对中间。** `String.take(60)` 数的是 UTF-16 码元。说明写成「第一天🌅」这种带 emoji 的句子时，第 60 个码元正好可能是 emoji 的高代理，切下去会留下一个孤立代理，`toByteArray(UTF_8)` 把它静默变成 `?`。所以截断走 `takeCodePoints`，在码点边界收口。

另外两条边界也顺手收了：说明里的**全角标点不替换**（`：` `｜` `？` 在任何文件系统上都是合法字符，只有 ASCII 的 `:` 才非法，把全角冒号改成下划线是无谓地毁掉一句中文）；说明恰好是 `CON`/`NUL`/`COM1` 这类 Windows 设备名时前面加 `_`，否则在 Windows 上这个文件永远打不开。

**为什么图库不参与系统云备份。** 数据库是文件的索引。只备份索引会还原出「有说明没有图」的半份数据，只备份文件会得到一堆没有说明的孤儿图。需要长期留存，走「导出 → 打包为 ZIP」这条显式路径。

---

## 五、构建

环境要求：JDK 17、Android SDK（`compileSdk 35` / `build-tools 35.0.0`）。

`local.properties` 里的 `sdk.dir` 指向本机 SDK：

```properties
sdk.dir=D\:\\AI\\deepseek\\android-sdk
```

```bash
# Debug（可直接安装）
./gradlew :app:assembleDebug
# → app/build/outputs/apk/debug/app-debug.apk

# Release（已配置签名）
./gradlew :app:assembleRelease
# → app/build/outputs/apk/release/app-release.apk

# 导出顺序契约的单元测试
./gradlew :app:testDebugUnitTest
```

Release 签名从项目目录之外读取 `../photolog-keystore.properties`（本机为 `D:\AI\deepseek\photolog-keystore.properties`），找不到时产出未签名 APK 而不是构建失败。

---

## 六、已验证

| 项 | 结果 |
|---|---|
| `:app:assembleDebug` | BUILD SUCCESSFUL |
| `:app:assembleRelease` | BUILD SUCCESSFUL |
| `:app:testDebugUnitTest` | `ExportNamingTest` **30 项**，failures 0 / errors 0 / skipped 0 |
| Release APK 签名 | `apksigner verify` 通过，APK Signature Scheme v2，签名者 `CN=PhotoLog` |
| Release APK 体积 | 2.61 MB（debug 版约 20 MB，未压缩未混淆） |
| 权限 | 仅 `android.permission.CAMERA`（另有无害的 `DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION`，由 androidx 自动声明） |
| 分享入口 | 合并后清单确认 `SEND` / `SEND_MULTIPLE` / `VIEW` 三个 filter 均带 `image/*` |
| 清单 | `package=io.photolog.android`、`minSdk 24`、`targetSdk 35`、`versionName 0.0.1`、`MainActivity` 为 `singleTop` |

单元测试覆盖的契约：

**命名与顺序** — 导出顺序等于图库顺序；序号前缀；无损保留原扩展名而压缩强制 `.jpg`；扩展名始终取自字节而非说明文字；同名去重；「最近 20 张」取最新但按图库顺序输出；原图缺失时跳过并如实计数。

**说明文字命名** — 中文说明直接成为文件名；全角标点保留而 ASCII 非法字符替换；说明里的 `/` 不会变成目录；多行说明压成一行；超长说明截断到 60 字；空白说明回退原文件名；同名说明加 `_2`；可切换回原文件名；Windows 设备名转义。

**中文专项** — ZIP 条目名是 `images/001_清晨的雾.jpg` 且能被 `ZipInputStream` 原样读回；本地文件头 bit 11（EFS）确实置位；图片字节与源文件逐字节相同（无损的实证）；截断不产生孤立代理、不出现 `U+FFFD`；`captions.txt` 以 `EF BB BF` 开头；Markdown / HTML 不带 BOM 且各自声明编码。

**说明文件结构** — Markdown 中每段说明紧跟自己的图片且整体有序；文档里的图片路径与实际导出文件名一致；无说明时写「（无说明）」；HTML `<figure>`/`<figcaption>` 配对；HTML 转义 `<script>`、`&`、`"`；文档如实记录无损/压缩模式。

---

## 七、已知限制

- **未在真机/模拟器上运行过。** 本次交付只做了编译、签名、清单与单元测试层面的验证；相机取景、SAF 落盘、分享接收的端到端行为需要在设备上实测。
- 图片不参与系统云备份，也不参与设备迁移（理由见上）。跨设备迁移请用 ZIP 导出。
- 单张照片的说明只支持纯文本，不支持富文本或 Markdown 渲染。
- 无损导出保留原始格式。若原始格式是 HEIC/AVIF，导出的仍是 HEIC/AVIF，接收方需要支持该格式。
- 压缩导出会烘焙 EXIF 旋转到像素并丢弃其它 EXIF；无损导出完全不动元数据。
- 应用私有的 `originals/` 目录随卸载一并删除。

---

## 八、目录结构

```
photolog-android/
├── app/src/main/kotlin/io/photolog/android/
│   ├── PhotoLogApplication.kt        进程级容器持有者
│   ├── AppContainer.kt               手写依赖容器
│   ├── MainActivity.kt               单 Activity + 分享 Intent 解析
│   ├── data/
│   │   ├── Database.kt               PhotoEntity / PhotoDao / PhotoLogDatabase
│   │   ├── MimeTypes.kt              类型判定与扩展名映射
│   │   ├── PhotoRepository.kt        文件落盘、导入、去重、排序、删除
│   │   ├── SettingsStore.kt          DataStore 设置
│   │   ├── ShareIntake.kt            分享事件通道
│   │   └── Messages.kt               一次性提示文本
│   ├── export/
│   │   ├── ExportModels.kt           导出模型、命名计划、说明文件生成
│   │   └── Exporter.kt               ZIP / 目录 / 单张 / 仅说明，无损与压缩两条写入路径
│   ├── ui/
│   │   ├── Theme.kt                  配色与主题模式
│   │   ├── Components.kt             PhotoCard、徽章、空状态、格式化
│   │   ├── PhotoLogRoot.kt           路由、底部导航、分享消费
│   │   ├── GalleryScreen.kt          图库
│   │   ├── CaptureScreen.kt          CameraX 拍照
│   │   ├── DetailScreen.kt           单张编辑
│   │   ├── ExportScreen.kt           导出
│   │   └── SettingsScreen.kt         设置
│   └── vm/ViewModels.kt              五个 ViewModel + 工厂
└── app/src/test/kotlin/io/photolog/android/export/ExportNamingTest.kt
```
