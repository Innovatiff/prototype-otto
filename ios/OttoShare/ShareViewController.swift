import Social
import UniformTypeIdentifiers

/// Share anything to Otto → it lands in the capture queue and becomes a
/// task the next time the app foregrounds. Capture must never fail: the
/// queue is App Group storage, no network, no sign-in required here.
final class ShareViewController: SLComposeServiceViewController {

    override func viewDidLoad() {
        super.viewDidLoad()
        placeholder = "Note for Otto…"
    }

    override func isContentValid() -> Bool {
        true
    }

    override func didSelectPost() {
        let typed = (contentText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let provider = firstURLProvider()
        // Inherits MainActor: nothing non-Sendable crosses an isolation
        // boundary — the item-provider callback resumes with a plain URL.
        Task {
            var entry = typed
            if let provider {
                let url: URL? = await withCheckedContinuation { continuation in
                    provider.loadItem(forTypeIdentifier: UTType.url.identifier) { item, _ in
                        continuation.resume(returning: item as? URL)
                    }
                }
                if let url {
                    entry += (entry.isEmpty ? "" : " — ") + url.absoluteString
                }
            }
            if !entry.isEmpty {
                CaptureQueue.append(entry)
            }
            self.extensionContext?.completeRequest(returningItems: nil)
        }
    }

    override func configurationItems() -> [Any]! {
        []
    }

    /// First URL attachment, if the share carried one (Safari, links).
    private func firstURLProvider() -> NSItemProvider? {
        let providers = (extensionContext?.inputItems as? [NSExtensionItem])?
            .compactMap(\.attachments)
            .flatMap { $0 } ?? []
        return providers.first {
            $0.hasItemConformingToTypeIdentifier(UTType.url.identifier)
        }
    }
}
