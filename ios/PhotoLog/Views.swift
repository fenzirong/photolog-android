import SwiftUI
import PhotosUI
import PhotoLogKit

/// The library.
///
/// Reading order is the feature: image → caption → metadata. The caption sits immediately under
/// the photo, which is what makes 「照片下面可以打文字说明」 true of the list and not just of a form.
struct GalleryView: View {
    let store: LibraryStore
    @Environment(SettingsStore.self) private var settings

    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var importing = false
    @State private var detailTarget: Photo?
    @State private var pendingDelete: Photo?

    var body: some View {
        NavigationStack {
            List {
                if store.allPhotos().isEmpty {
                    Section {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("图库还是空的").font(.headline)
                            Text("用「拍照」拍一张，或点右上角从相册导入；也可以在其他应用里选中图片，用「分享」发送到「图志」。")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 24)
                    }
                } else {
                    Section {
                        Text("共 \(store.count()) 张 · 占用 \(formatBytes(store.totalBytes()))")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(Array(store.allPhotos().enumerated()), id: \.element.id) { index, photo in
                        PhotoCard(store: store, photo: photo, position: index + 1)
                            .contentShape(Rectangle())
                            .onTapGesture { detailTarget = photo }
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) { pendingDelete = photo } label: {
                                    Label("删除", systemImage: "trash")
                                }
                                Button { store.move(photo, by: -1) } label: {
                                    Label("上移", systemImage: "arrow.up")
                                }
                                Button { store.move(photo, by: 1) } label: {
                                    Label("下移", systemImage: "arrow.down")
                                }
                            }
                    }
                }
            }
            .navigationTitle("图库")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    PhotosPicker(
                        selection: $pickerItems,
                        maxSelectionCount: 50,
                        matching: .images
                    ) {
                        Image(systemName: "photo.badge.plus")
                    }
                }
                ToolbarItem(placement: .topBarLeading) {
                    if importing { ProgressView() }
                }
            }
            .sheet(item: $detailTarget) { photo in
                DetailView(store: store, photo: photo)
            }
            .alert("删除这张照片？", isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            )) {
                Button("删除", role: .destructive) {
                    if let photo = pendingDelete { store.delete([photo]) }
                    pendingDelete = nil
                }
                Button("取消", role: .cancel) { pendingDelete = nil }
            } message: {
                Text("照片文件和它的文字说明会一起删除，无法撤销。")
            }
            // The system photo picker hands over a copy the app can read, so no photo-library
            // permission is involved — the same posture as `PickVisualMedia` on Android.
            .onChange(of: pickerItems) { _, items in
                guard !items.isEmpty else { return }
                Task { await importPicked(items) }
            }
        }
    }

    private func importPicked(_ items: [PhotosPickerItem]) async {
        importing = true
        defer {
            importing = false
            pickerItems = []
        }
        for item in items {
            guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
            let temp = FileManager.default.temporaryDirectory
                .appendingPathComponent("picked-\(UUID().uuidString)")
            guard (try? data.write(to: temp)) != nil else { continue }
            let name = "IMG_\(UUID().uuidString.prefix(8)).jpg"
            await store.importFile(at: temp, originalName: name, mimeType: "image/jpeg", source: "GALLERY")
            try? FileManager.default.removeItem(at: temp)
        }
    }
}

/// One entry in the library.
struct PhotoCard: View {
    let store: LibraryStore
    let photo: Photo
    let position: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let image = UIImage(contentsOfFile: store.url(for: photo).path) {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .background(Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }

            HStack(spacing: 6) {
                Text(String(format: "%03d", position))
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.15))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                Text(sourceLabel(photo.source))
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.15))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                Spacer()
                Text(formatDateTime(photo.capturedAt))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Text(photo.caption.isEmpty ? "点这里给这张照片写一行文字说明" : photo.caption)
                .font(.body)
                .italic(photo.caption.isEmpty)
                .foregroundStyle(photo.caption.isEmpty ? Color.secondary : Color.primary)
                .lineLimit(4)

            Text("\(photo.width) × \(photo.height) · \(formatBytes(photo.sizeBytes)) · \(photo.mimeType)")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}

/// One photo's editor.
struct DetailView: View {
    let store: LibraryStore
    let photo: Photo

    @Environment(\.dismiss) private var dismiss
    @State private var caption: String = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let image = UIImage(contentsOfFile: store.url(for: photo).path) {
                        Image(uiImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(maxWidth: .infinity)
                            .background(Color(.secondarySystemBackground))
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }

                    TextField("这是什么时候、在哪、拍的什么？", text: $caption, axis: .vertical)
                        .lineLimit(3...6)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: caption) { _, value in
                            store.setCaption(photo, to: value)
                        }

                    Text("输入后自动保存；导出时这段文字会跟在对应图片下面，按顺序一起写进说明文件。")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Divider()

                    VStack(alignment: .leading, spacing: 4) {
                        DetailRow(
                            label: "文件名",
                            value: photo.originalName.isEmpty ? photo.fileName : photo.originalName
                        )
                        DetailRow(label: "尺寸", value: photo.width > 0 ? "\(photo.width) × \(photo.height)" : "未知")
                        DetailRow(label: "大小", value: formatBytes(photo.sizeBytes))
                        DetailRow(label: "格式", value: photo.mimeType)
                        DetailRow(label: "拍摄时间", value: formatDateTime(photo.capturedAt))
                        DetailRow(label: "导入方式", value: sourceLabel(photo.source))
                        DetailRow(label: "顺序", value: "\(photo.sortIndex)（导出时按此顺序）")
                    }
                }
                .padding()
            }
            .navigationTitle("第 \(photo.sortIndex) 张")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("完成") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(role: .destructive) {
                        store.delete([photo])
                        dismiss()
                    } label: {
                        Image(systemName: "trash")
                    }
                }
            }
            .onAppear { caption = photo.caption }
        }
    }
}

struct DetailRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .top) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 72, alignment: .leading)
            Text(value).font(.caption)
        }
    }
}

/// Export.
struct ExportView: View {
    let store: LibraryStore
    @Environment(SettingsStore.self) private var settings

    @State private var scope: ExportScope = .all
    @State private var archive: ExportedArchive?
    @State private var showingExporter = false
    @State private var message: String?

    private enum Kind { case zip, captions }

    private var photos: [Photo] { store.allPhotos() }

    private var planned: Int {
        ExportNaming.plan(
            photos: photos.map(\.record),
            scope: scope,
            options: settings.settings.exportOptions
        ).count
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("导出范围") {
                    Picker("范围", selection: $scope) {
                        ForEach(ExportScope.allCases, id: \.self) { value in
                            Text(value.label).tag(value)
                        }
                    }
                    .pickerStyle(.segmented)
                    Text("当前将导出 \(planned) 张，顺序就是「图库」里的顺序。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("图片质量") {
                    Toggle("无损导出（推荐）", isOn: Binding(
                        get: { settings.exportLossless },
                        set: { settings.exportLossless = $0 }
                    ))
                    Text(settings.exportLossless
                         ? "原样复制文件字节，不重新编码，EXIF、色彩信息和画质 100% 保留。"
                         : "会解码后重新编码为 JPEG，画质有损但文件更小。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("文字说明") {
                    Toggle("导出图片下方的文字说明", isOn: Binding(
                        get: { settings.exportIncludeCaptions },
                        set: { settings.exportIncludeCaptions = $0 }
                    ))
                    Picker("格式", selection: Binding(
                        get: { settings.exportCaptionFormat },
                        set: { settings.exportCaptionFormat = $0 }
                    )) {
                        ForEach(CaptionFormat.allCases, id: \.self) { format in
                            Text(format.label).tag(format)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Section("文件命名") {
                    Picker("来源", selection: Binding(
                        get: { settings.exportNameFromCaption },
                        set: { settings.exportNameFromCaption = $0 }
                    )) {
                        Text("用图片下方的说明文字").tag(true)
                        Text("用原文件名").tag(false)
                    }
                    .pickerStyle(.segmented)
                    Toggle("加序号前缀（001_、002_…）", isOn: Binding(
                        get: { settings.exportNumbered },
                        set: { settings.exportNumbered = $0 }
                    ))
                }

                Section("输出方式") {
                    Button("打包为 ZIP（图片 + 说明文件）") { run(.zip) }
                        .disabled(planned == 0)
                    Button("只导出说明文件") { run(.captions) }
                        .disabled(planned == 0)
                }
            }
            .navigationTitle("导出")
            .fileExporter(
                isPresented: $showingExporter,
                document: archive,
                contentType: .zip,
                defaultFilename: archive?.suggestedName ?? "图志导出"
            ) { result in
                switch result {
                case .success: message = "已导出"
                case .failure(let error): message = "导出失败：\(error.localizedDescription)"
                }
            }
            .alert(message ?? "", isPresented: Binding(
                get: { message != nil },
                set: { if !$0 { message = nil } }
            )) {
                Button("好", role: .cancel) { message = nil }
            }
        }
    }

    private func run(_ kind: Kind) {
        do {
            let options = settings.settings.exportOptions
            switch kind {
            case .zip:
                archive = try Exporter.makeArchive(
                    photos: photos,
                    store: store,
                    scope: scope,
                    options: options
                )
            case .captions:
                archive = try Exporter.captionsOnly(photos: photos, scope: scope, options: options)
            }
            showingExporter = true
        } catch {
            message = error.localizedDescription
        }
    }
}

/// Settings.
struct SettingsView: View {
    let store: LibraryStore
    @Environment(SettingsStore.self) private var settings
    @State private var confirmClear = false

    var body: some View {
        NavigationStack {
            Form {
                Section("外观") {
                    Picker("主题", selection: Binding(
                        get: { settings.themeMode },
                        set: { settings.themeMode = $0 }
                    )) {
                        Text("跟随系统").tag("system")
                        Text("浅色").tag("light")
                        Text("深色").tag("dark")
                    }
                    .pickerStyle(.segmented)
                }

                Section("存储") {
                    Text("共 \(store.count()) 张照片，占用 \(formatBytes(store.totalBytes()))。原图保存在应用私有目录，卸载应用会一并删除。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("按拍摄时间重排导出顺序") { store.sortByCapturedAt() }
                    Button("清空图库", role: .destructive) { confirmClear = true }
                }

                Section("关于") {
                    Text("图志把「照片 + 它下面的一行文字」当作一个整体：拍下或收下的图片原样保存，说明写在图片下方，导出时可以按当前顺序把图片和说明一起带走。")
                    Text("接收分享：在相册、文件管理器或聊天应用里选中图片，用「分享」发送到「图志」即可入库。")
                    Text("无损导出：导出时默认按字节复制原始文件，不重新编码，EXIF 与画质完全保留。")
                    Text("隐私：应用只申请相机权限。相册导入使用系统照片选择器，导出走系统文件选择器，由你指定写入位置。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("版本 0.0.1（iOS 版）")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("设置")
            .alert("清空图库？", isPresented: $confirmClear) {
                Button("全部删除", role: .destructive) { store.deleteAll() }
                Button("取消", role: .cancel) {}
            } message: {
                Text("将删除全部 \(store.count()) 张照片及其文字说明，无法撤销。")
            }
        }
    }
}
