import Social
import UniformTypeIdentifiers

/// Share anything to Otto → it lands in the capture queue and becomes a
/// task the next time the app foregrounds. Capture must never fail: the
/// queue is App Group storage, no network, no sign-in required here.
final class ShareViewController: SLComposeServiceViewController {

    override func isContentValid() -> Bool {
        true
    }

    override func placeholder(for controller: SLComposeServiceViewController) -> String! {
        "Note for Otto…"
    }

    override func didSelectPost() {
        let typed = (contentText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        loadSharedURL { url in
            var entry = typed
            if let url {
                entry += (entry.isEmpty ? "" : " — ") + url.absoluteString
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
    private func loadSharedURL(completion: @escaping (URL?) -> Void) {
        let providers = (extensionContext?.inputItems as? [NSExtensionItem])?
            .compactMap(\.attachments)
            .flatMap { $0 } ?? []
        guard
            let provider = providers.first(where: {
                $0.hasItemConformingToTypeIdentifier(UTType.url.identifier)
            })
        else {
            completion(nil)
            return
        }
        provider.loadItem(forTypeIdentifier: UTType.url.identifier) { item, _ in
            DispatchQueue.main.async {
                completion(item as? URL)
            }
        }
    }
}
