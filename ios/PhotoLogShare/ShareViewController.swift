import UIKit
import UniformTypeIdentifiers

/// The share extension.
///
/// iOS has no `ACTION_SEND` equivalent: an app cannot be handed content by another app directly.
/// The only door in is the system share sheet, and the only thing that appears there is a Share
/// Extension — which is a **separate process** with its own sandbox. That is why this exists at all,
/// and why it does not simply call into the app.
///
/// The two processes meet at an App Group container. This extension copies each shared image into
/// `Inbox/` and writes a `manifest.json` describing them; the app drains that inbox on launch and
/// whenever it returns to the foreground. A manifest plus files rather than a shared database,
/// because concurrent writers to one SwiftData store across two processes is a real hazard while
/// write-then-move is not.
///
/// The activation rule in `Info.plist` restricts this to the image family, matching the `utd`
/// declaration on the HarmonyOS build and the `image/*` intent filter on the Android one.
final class ShareViewController: UIViewController {

    private let statusLabel = UILabel()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        statusLabel.text = "正在导入到图志…"
        statusLabel.textAlignment = .center
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(statusLabel)
        NSLayoutConstraint.activate([
            statusLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            statusLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            statusLabel.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -24),
        ])

        Task { await handleSharedItems() }
    }

    private func handleSharedItems() async {
        let attachments = (extensionContext?.inputItems as? [NSExtensionItem])?
            .flatMap { $0.attachments ?? [] } ?? []

        guard let inbox = AppGroup.inboxURL else {
            await finish(message: "无法访问共享目录")
            return
        }

        var items: [SharedItem] = []
        for attachment in attachments {
            guard let item = await copyToInbox(attachment, inbox: inbox) else { continue }
            items.append(item)
        }

        if items.isEmpty {
            await finish(message: "没有可导入的图片")
            return
        }

        let manifestURL = inbox.appendingPathComponent("manifest.json")
        if let data = try? JSONEncoder().encode(items) {
            try? data.write(to: manifestURL)
        }

        await finish(message: "已导入 \(items.count) 张照片")
    }

    /// Copies one attachment into the inbox.
    ///
    /// `loadFileRepresentation` hands over a temporary file that is deleted as soon as the
    /// completion handler returns, so the copy has to happen inside it — reading the URL later is
    /// the classic reason a share extension "succeeds" and the app then finds nothing.
    private func copyToInbox(_ provider: NSItemProvider, inbox: URL) async -> SharedItem? {
        let typeIdentifier = provider.registeredTypeIdentifiers.first {
            UTType($0)?.conforms(to: .image) ?? false
        } ?? UTType.image.identifier

        return await withCheckedContinuation { continuation in
            provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { url, _ in
                guard let url else {
                    continuation.resume(returning: nil)
                    return
                }
                let originalName = url.lastPathComponent
                let ext = url.pathExtension.isEmpty ? "jpg" : url.pathExtension
                let fileName = "\(UUID().uuidString).\(ext)"
                let destination = inbox.appendingPathComponent(fileName)
                do {
                    try FileManager.default.copyItem(at: url, to: destination)
                    let mime = UTType(filenameExtension: ext)?.preferredMIMEType ?? "image/jpeg"
                    continuation.resume(
                        returning: SharedItem(fileName: fileName, originalName: originalName, mimeType: mime)
                    )
                } catch {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    private func finish(message: String) async {
        await MainActor.run {
            statusLabel.text = message
            extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
        }
    }
}
