# 图志 PhotoLog · iOS 版

iOS 版本的图志。与 Android 版、HarmonyOS 版功能对齐：拍照存档、图片下方文字说明、
接收系统分享、无损导出、按图库顺序导出图片与说明文件。

技术栈是第三套：**Swift + SwiftUI + SwiftData + AVFoundation**，构建用 Xcode。

---

## 验证状态：核心逻辑已由 macOS CI 真编译真跑过

这个仓库没有 Mac，但**有一个 macOS runner**。所以把平台无关的那一半拆成了独立的
`PhotoLogKit` Swift Package——导出顺序、文件命名、ZIP 写入——由 `.github/workflows/ios-verify.yml`
在 `macos-latest` 上跑 `swift test`：不需要模拟器、不需要签名、不需要 Xcode 工程。

**当前状态：CI 绿。27 个 XCTest 全部通过。**

```bash
cd ios/PhotoLogKit && swift test     # macOS 上一条命令即可复现
```

测试覆盖：

- **命名与顺序契约**（与另两个平台逐条对齐）：导出顺序 = 图库顺序、序号前缀、中文说明成为文件名、
  全角标点保留而 ASCII 非法字符替换、多行压成一行、超长截断到 60 字、emoji 与 ZWJ 序列不被切断、
  同名加 `_2`、Windows 设备名转义、无损保留扩展名而压缩强制 `.jpg`
- **说明文档**：Markdown 中每段说明紧跟自己的图片且整体有序、图片路径与文件名一致、
  `captions.txt` 前置 UTF-8 BOM、Markdown/HTML 不带 BOM、HTML 转义 `<script>`
- **ZIP 字节**：本地文件头/中央目录/EOCD 签名、EFS（UTF-8 名）标志位、压缩方法为 STORE、
  CRC-32、条目偏移
- **真实解压往返**：交给 `/usr/bin/ditto`（Apple 自家工具，Finder 的 Archive Utility 就用它）
  解压，确认中文条目名 `images/001_清晨的雾.jpg` 原样还原、图片字节逐字节相同

### CI 抓到的两个真问题

**1. 编译错误。** `CaptionDocument.build` 里三处调用漏了参数标签：

```
ExportModels.swift:315:40: error: missing argument label 'plan:' in call
```

`markdown/html/text` 的首参数声明为 `plan:`，我却按位置传了。本机无 Swift 工具链，只有 CI 能抓到。

**2. 测试用错了 macOS 的解压器。** 第一版用 `/usr/bin/unzip`，报：

```
error: cannot create .../images/001_���ֿ������.jpg
```

`清晨的雾` 的 UTF-8 字节被按别的编码重读再重编码——**典型的解压器无视 EFS 标志位**。
macOS 自带的 `/usr/bin/unzip` 是老版 Info-ZIP 6.00，不认 UTF-8 条目名；这是那个二进制的缺陷，
**不是归档的问题**——同一份字节在 Windows 的 `Expand-Archive` 下解压正确（鸿蒙版已验证过）。
改用 `ditto` 后通过。

---

## 未验证的部分

**app 层（SwiftUI 视图、AVFoundation 拍照、分享扩展、SwiftData 模型）未经编译。**
它们依赖 SwiftUI / AVFoundation / PhotosUI / UIKit，这些框架在 Windows 上根本不存在，
本机也没有 Swift 工具链（`swift`/`swiftc` 不在 PATH；MSVC 与 Windows SDK 只有空壳目录，
而 Swift for Windows 需要完整 C++ 工作负载）。首次在 Xcode 中打开时出现编译错误是可能的。

由 macOS CI 覆盖的只有 `PhotoLogKit`。这一点我写在最前面，而不是藏在末尾。

---

## 目录结构

```
ios/
├── project.yml                    XcodeGen 规格（生成 .xcodeproj）
├── PhotoLogKit/                   ★ 平台无关逻辑，由 macOS CI 验证
│   ├── Package.swift
│   ├── Sources/PhotoLogKit/
│   │   ├── ExportModels.swift     命名 + 顺序 + 说明文档
│   │   └── ZipWriter.swift        手写 ZIP + CRC-32
│   └── Tests/PhotoLogKitTests/ExportTests.swift
├── PhotoLog/                      app target
│   ├── PhotoLogApp.swift          @main + TabView + 分享收件箱排空
│   ├── Data.swift                 SwiftData 模型 + App Group + 设置
│   ├── LibraryStore.swift         沙箱文件、去重、排序、删除
│   ├── CaptureView.swift          AVFoundation 拍照 + 预览
│   ├── Exporter.swift             FileDocument + ZIP / 散图 / 仅说明
│   ├── Views.swift                图库 / 详情 / 导出 / 设置
│   └── PhotoLog.entitlements      App Group
└── PhotoLogShare/                 分享扩展 target
    ├── ShareViewController.swift
    └── PhotoLogShare.entitlements
```

---

## 关键实现

### 接收系统分享：为什么必须是一个扩展

iOS **没有** `ACTION_SEND` 的对应物——一个应用不能直接被另一个应用交付内容。唯一的入口是系统
分享面板，而唯一能出现在那里的是 **Share Extension**，它是**独立进程、独立沙箱**。

所以这里是两个 target，靠 App Group 容器对接：扩展把每张图复制进 `Inbox/` 并写 `manifest.json`，
主 app 在启动时与每次回到前台时排空。用「文件 + 清单」而不是共享数据库，是因为两个进程并发写同一个
SwiftData store 是真实的风险，而「写完再移走」不是。

复制必须发生在 `loadFileRepresentation` 的回调**内部**：它给的是一个临时文件，回调一返回就被删除。
在回调外读那个 URL，就是「扩展提示成功、主 app 却什么都找不到」的经典原因。

### ZIP 为什么自己写

`Foundation` 没有 ZIP API；`AppleArchive` 写的是苹果自己的格式而非 ZIP；第三方库则是为控制
**一个 bit** 而引入大量代码——而那个 bit 正是关键：通用标志位 bit 11（EFS）声明条目名是 UTF-8。
没有它，Windows 解压器按系统代码页读字节，每个中文名都是乱码。

method 0（STORE）：每个条目都是照片，JPEG/PNG/HEIC 本身已压缩，DEFLATE 只白耗 CPU。
CRC-32 两遍扫描，因为本地文件头在数据之前、必须已经带上 CRC。

### 三个平台的截断单位差异

Android 按 UTF-16 码元、HarmonyOS 按码点、iOS 按 Swift 的 `Character`（**扩展字素簇**）。
对纯中文三者完全一致；emoji 场景下 iOS 最严格——它连 ZWJ 组合序列（如 👨‍👩‍👧）都不会切开。
三者的可观察要求相同：不切开一个字符。

---

## 怎么构建

需要 **macOS + Xcode 15 或更新版本**。

```bash
brew install xcodegen
cd ios
xcodegen generate          # 生成 PhotoLog.xcodeproj
open PhotoLog.xcodeproj
```

然后在 Xcode 里：

1. 选中 `PhotoLog` target → Signing & Capabilities → 选你的 Team
2. **两个 target 都要**开启 App Groups，且都勾选 `group.io.photolog`
   （扩展与主 app 必须属于同一个 group，否则分享进来的图片会写到一个主 app 读不到的地方）
3. 连接设备或选模拟器，Run

只跑核心逻辑的测试（不需要 Xcode 工程、不需要签名）：

```bash
cd ios/PhotoLogKit && swift test
```

---

## 与另两个平台的差异

| | Android | HarmonyOS NEXT | iOS |
|---|---|---|---|
| 语言 / UI | Kotlin + Compose | ArkTS + ArkUI | Swift + SwiftUI |
| 构建 | Gradle | hvigor | Xcode |
| 数据库 | Room | RDB | SwiftData |
| 设置 | DataStore | Preferences | UserDefaults |
| 拍照 | CameraX | CameraKit | AVFoundation |
| 相册导入 | `PickVisualMedia` | `PhotoViewPicker` | `PhotosPicker` |
| 接收分享 | `ACTION_SEND` intent filter | `ohos.want.action.sendData` + `utd` | **Share Extension + App Group** |
| 导出落盘 | Storage Access Framework | `DocumentViewPicker` | `.fileExporter` |
| 归档 | `java.util.zip` | 自写 ZIP | 自写 ZIP |
| 权限 | 仅 `CAMERA` | 仅 `ohos.permission.CAMERA` | 仅 `NSCameraUsageDescription` |

三版的导出命名规则、说明文档格式、ZIP 条目命名与中文处理**逐条对齐**，同一批照片在任一端
导出的结果应当一致。

---

## 已知限制

- **app 层未经编译**（原因见上）。
- 导出目前只有 ZIP 与仅说明文件两种；`Exporter.looseItems`（散图导出）已实现，但
  `.fileExporter` 一次只接受一个文档，多文件导出需要走 `UIDocumentPickerViewController`
  或分享面板，尚未接线。
- 压缩导出（有损）未实现降采样；`ExportOptions.maxLongEdge` 在 iOS 侧暂未生效。
- 相机只用后置摄像头，未做前后摄切换与闪光灯控制（Android 版有）。
