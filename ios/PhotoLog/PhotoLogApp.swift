import SwiftUI
import SwiftData
import PhotoLogKit

/// The app entry point.
///
/// One `TabView` with the same four destinations as the other two builds, and one place where the
/// share inbox is drained.
@main
struct PhotoLogApp: App {
    @State private var settings = SettingsStore()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(settings)
                .preferredColorScheme(colorScheme)
        }
        .modelContainer(for: Photo.self)
        .onChange(of: scenePhase) { _, phase in
            // The share extension writes into the App Group container while this app may be in the
            // background, so the inbox is drained on the way back in rather than only at launch.
            if phase == .active {
                NotificationCenter.default.post(name: .photoLogDrainInbox, object: nil)
            }
        }
    }

    private var colorScheme: ColorScheme? {
        switch settings.themeMode {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }
}

extension Notification.Name {
    static let photoLogDrainInbox = Notification.Name("photoLogDrainInbox")
}

struct RootView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var store: LibraryStore?
    @State private var selectedTab: Int = 0

    var body: some View {
        Group {
            if let store {
                TabView(selection: $selectedTab) {
                    GalleryView(store: store)
                        .tabItem { Label("图库", systemImage: "photo.on.rectangle") }
                        .tag(0)

                    CaptureView(store: store)
                        .tabItem { Label("拍照", systemImage: "camera") }
                        .tag(1)

                    ExportView(store: store)
                        .tabItem { Label("导出", systemImage: "square.and.arrow.up") }
                        .tag(2)

                    SettingsView(store: store)
                        .tabItem { Label("设置", systemImage: "gearshape") }
                        .tag(3)
                }
            } else {
                ProgressView()
            }
        }
        .task {
            let created = LibraryStore(context: modelContext)
            store = created
            await ShareInbox.drain(store: created)
        }
        .onReceive(NotificationCenter.default.publisher(for: .photoLogDrainInbox)) { _ in
            guard let store else { return }
            Task { await ShareInbox.drain(store: store) }
        }
    }
}

// MARK: - formatting

func formatBytes(_ bytes: Int64) -> String {
    let formatter = ByteCountFormatter()
    formatter.allowedUnits = [.useKB, .useMB, .useGB]
    formatter.countStyle = .file
    return formatter.string(fromByteCount: bytes)
}

func formatDateTime(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH:mm"
    return formatter.string(from: date)
}

func sourceLabel(_ source: String) -> String {
    switch source {
    case "CAMERA": return "拍照"
    case "SHARE": return "分享"
    default: return "相册"
    }
}
