# 图志 PhotoLog · HarmonyOS NEXT 版

华为**纯血鸿蒙**（HarmonyOS NEXT，API 12）版本的图志。与仓库根目录的 Android 版功能对齐：
拍照存档、图片下方文字说明、接收系统分享、无损导出、按图库顺序导出图片与说明文件。

技术栈是另一套：**ArkTS + ArkUI + RDB + CameraKit**，构建工具是 hvigor 而不是 Gradle。

---

## ⚠️ 先说清楚：这个工程没有在 HarmonyOS 上编译验证过

**这台机器上无法构建，也无法产出可安装的产物**，原因是硬性的：

| 依赖 | 状态 |
|---|---|
| HarmonyOS SDK（`@kit.*`） | 华为开发者账号门控。`developer.huawei.com` 返回 403 |
| hvigor 构建系统（`@ohos/hvigor`、`@ohos/hvigor-ohos-plugin`） | 不在公共 npm（`registry.npmjs.org/@ohos/hvigor` → 404），只在华为门控 registry |
| **应用签名** | 纯血鸿蒙的 `.hap` 必须用**华为 AGC 签发的 `.p12` + `.p7b` profile** 签名才能安装。这一点与工具链无关——即使 SDK 到手，没有华为签发的证书仍然装不上 |

所以：**ArkTS 代码未经编译器检查，UI 未经真机验证。** 下面的「已验证」一节写的是我实际能验的部分，不是推测。

（作为对照：仓库里的 Android 版本走的是完整闭环——编译、签名、30 项单测、CI 发布、产物独立校验。鸿蒙版目前只到源码交付。）

---

## 已验证的部分

导出逻辑（顺序、命名、说明文档、ZIP 字节）是纯 TypeScript，不依赖任何鸿蒙 API，因此可以在这台机器上真跑：

```bash
node harmonyos/tools/verify-export.mjs
# 67 passed, 0 failed
```

`tools/verify-export.mjs` **跑的就是 `entry/src/main/ets/export/` 下的两份 `.ets` 源码本身**（复制为 `.ts` 后 import），不是另写的副本——所以不存在"测试通过但产品代码不同"的漂移。它验证：

- 命名与顺序契约：导出顺序 = 图库顺序、序号前缀、中文说明成为文件名、全角标点保留而 ASCII 非法字符替换、多行压成一行、超长截断到 60 码点、emoji 不被切断、同名加 `_2`、Windows 设备名转义
- 说明文档：Markdown 中每段说明紧跟自己的图片且整体有序、图片路径与实际文件名一致、`captions.txt` 前置 UTF-8 BOM、Markdown/HTML 不带 BOM、HTML 转义 `<script>`
- **ZIP 字节**：本地文件头/中央目录/EOCD 签名、CRC-32（与 Node `zlib.crc32` 交叉核对）、条目偏移、压缩方法为 STORE、**通用标志位 bit 11（EFS）置位**
- **真实解压往返**：把产出的 ZIP 交给 **Windows 自带的 `Expand-Archive`**，确认中文条目名 `images/001_清晨的雾.jpg` 原样还原、图片字节逐字节相同、说明文件内容正确

### 这个夹具抓到过什么

初版 `utf8Encode` 有个真 bug：写 U+FFFD 的分支只在「后面还有字符」时才进得去，所以**结尾的孤立高代理**会被当成 3 字节 BMP 字符编码成 `ED A0 BC`（CESU-8），也就是**非法 UTF-8**——会作为畸形字节序列写进 ZIP 条目名。同时长度预算循环与写入循环结构不一致，遇到「高代理 + 非低代理」时预算多算 1 字节，输出数组尾部会留一个未写入的 `0`。两个都已修复并有回归用例。

---

## 目录结构

```
harmonyos/
├── AppScope/
│   ├── app.json5                      bundleName / 版本号 / 图标 / 名称
│   └── resources/base/
│       ├── element/string.json
│       └── media/app_icon.png         由 tools/make-icons.mjs 生成
├── build-profile.json5                products / modules / compatibleSdkVersion
├── hvigorfile.ts                      appTasks
├── oh-package.json5
├── entry/
│   ├── build-profile.json5
│   ├── hvigorfile.ts                  hapTasks
│   ├── oh-package.json5
│   └── src/main/
│       ├── module.json5               ★ 含接收分享的 skills 声明
│       ├── ets/
│       │   ├── entryability/EntryAbility.ets      分享 Want 解析 + 冷/热启动
│       │   ├── data/ShareIntake.ets               分享事件队列
│       │   ├── data/PhotoDatabase.ets             RDB（表 photos）
│       │   ├── data/PhotoRepository.ets           沙箱文件、去重、排序、删除
│       │   ├── data/SettingsStore.ets             Preferences
│       │   ├── export/ExportModels.ets            ★ 纯逻辑：命名 + 说明文档
│       │   ├── export/ZipWriter.ets               ★ 纯逻辑：手写 ZIP + CRC32
│       │   ├── export/Exporter.ets                单张 / ZIP / 散图 / 仅说明
│       │   └── pages/Index.ets                    四页 Tab + 详情面板
│       └── resources/base/
│           ├── element/{string,color}.json
│           ├── media/startIcon.png
│           └── profile/main_pages.json
└── tools/
    ├── verify-export.mjs              导出逻辑的 Node 验证夹具
    └── make-icons.mjs                 生成 PNG 图标
```

---

## 关键实现

### 接收系统分享

`module.json5` 里给 `EntryAbility` 声明第二个 skill：

```json5
{
  "actions": ["ohos.want.action.sendData"],
  "uris": [{ "scheme": "file", "utd": "general.image", "maxFileSupported": 9 }]
}
```

- `ohos.want.action.sendData` 是分享面板派发的 action
- `utd`（Uniform Type Descriptor）声明接收方支持的内容类型，`general.image` 覆盖图片族
- **`utd` 写错不会报错**——应用只是永远不出现在分享面板里，这是最难归因的一类失败

数据从两个地方来，`EntryAbility.collectSharedUris` 都读：`want.uri`（单张）与 `want.parameters['ability.params.stream']`（多张的 `Array<string>`）。只读前者，就是「多选图片分享进来没反应」的经典原因。

冷启动时 `onCreate` 早于任何页面组合，所以分享走 `ShareIntake` 队列；热启动走 `onNewWant`。队列而非单槽，是因为生产者在消费者存在之前就已经跑完了。

### 无损导出

与 Android 版同一条原则：**原始文件只被读，从不被重写**。`Exporter.writeImageBytes` 的无损分支就是一次 64 KiB 分块的字节复制，EXIF 与画质完全保留。压缩分支走 `ImagePacker`，单独成段，方便一眼看出「无损承诺」依赖的是哪条路径。

### ZIP 为什么自己写

`@ohos.zlib.compressFile` 作用于路径而非流，且无法控制条目名及其编码标志位——而**中文文件名在 ZIP 里的编码标志位，正是它在 Windows 上解压乱码的唯一原因**。所以归档自己写：method 0（STORE，照片本身已压缩，DEFLATE 只会白耗 CPU）、CRC-32 两遍扫描、条目名 UTF-8 且**通用标志位 bit 11（EFS）无条件置位**。

### 导出文件命名

与 Android 版一致：有说明就以说明命名（`001_清晨的雾.jpg`），没有就回退原文件名，可切换。中文无需特殊处理——CJK 表意文字、全角标点（`：`、`｜`）在任何目标文件系统上都合法，过滤器只去掉真正非法的字符。

---

## 怎么构建

需要 **DevEco Studio 5.0 或更新版本**（自带 HarmonyOS SDK、hvigor 与 ohpm），并登录华为开发者账号。

1. 用 DevEco Studio 打开 `harmonyos/` 目录（不是仓库根目录）
2. 首次打开会提示同步；`oh-package.json5` 无第三方依赖，不需要联网拉包
3. **配置签名**：`File → Project Structure → Signing Configs → 勾选 Automatically generate signature`，用华为账号自动申请调试证书
4. 连接 HarmonyOS NEXT 设备或启动模拟器，点 Run
5. 命令行构建（需先配好签名）：`hvigorw assembleHap --mode module -p product=default`

改图标后重新生成 PNG：`node tools/make-icons.mjs`

---

## 与 Android 版的差异

| | Android 版 | HarmonyOS NEXT 版 |
|---|---|---|
| 语言 / UI | Kotlin + Jetpack Compose | ArkTS + ArkUI |
| 构建 | Gradle | hvigor |
| 数据库 | Room（SQLite） | RDB（SQLite） |
| 设置 | DataStore Preferences | Preferences |
| 拍照 | CameraX | CameraKit |
| 相册导入 | `PickVisualMedia`（系统照片选择器） | `PhotoViewPicker` |
| 接收分享 | `ACTION_SEND` / `ACTION_SEND_MULTIPLE` | `ohos.want.action.sendData` + `utd` |
| 导出落盘 | Storage Access Framework | `DocumentViewPicker.save()` |
| 归档 | `java.util.zip` | 自写 ZIP（`ZipWriter.ets`） |
| 权限 | 仅 `CAMERA` | 仅 `ohos.permission.CAMERA` |

两版的导出命名规则、说明文档格式、ZIP 条目命名与中文处理**逐条对齐**，同一批照片在两端导出的结果应当一致。

---

## 已知限制

- **ArkTS 代码未经编译验证，UI 未经真机验证**（原因见上）。首次在 DevEco 中打开时出现编译报错是可能的，需要按 IDE 提示修正。
- 相机部分只用了后置摄像头，未做前后摄切换（Android 版有）。
- 压缩导出（有损）走 `ImagePacker`，未做最长边降采样。
- 主题切换目前只写入设置，未接入 ArkUI 的深浅色适配。
- `ShareIntake` 的队列在进程重启后清空——分享是事件，跨进程持久化没有意义。
