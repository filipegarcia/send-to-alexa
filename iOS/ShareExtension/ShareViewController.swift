import AlexaKit
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Entry point of the iOS share extension. Pulls the URL / text out of the share payload
/// and shows `ShareView` (device picker + Play button).
final class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground

        Task { @MainActor [weak self] in
            guard let self else { return }
            let (url, text) = await extractSharedContent()
            let model = ShareModel(service: AppEnvironment.service, sharedURL: url, sharedText: text)
            let root = ShareView(model: model) { [weak self] in
                self?.extensionContext?.completeRequest(returningItems: nil)
            }
            let host = UIHostingController(rootView: root)
            addChild(host)
            host.view.frame = view.bounds
            host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            view.addSubview(host.view)
            host.didMove(toParent: self)
        }
    }

    /// Apple Music shares a URL; other apps may share plain text that contains one.
    private func extractSharedContent() async -> (URL?, String?) {
        let items = extensionContext?.inputItems as? [NSExtensionItem] ?? []
        let providers = items.flatMap { $0.attachments ?? [] }

        var url: URL?
        var text: String?
        for provider in providers {
            if url == nil, provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                url = await Self.loadURL(from: provider)
            }
            if text == nil, provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                text = await Self.loadText(from: provider)
            }
        }
        // Some apps put a title in the item's attributed content text.
        if text == nil {
            text = items.first?.attributedContentText?.string
        }
        return (url, text)
    }

    private static func loadURL(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { item, _ in
                switch item {
                case let url as URL:
                    continuation.resume(returning: url)
                case let data as Data:
                    continuation.resume(returning: String(data: data, encoding: .utf8).flatMap(URL.init(string:)))
                case let string as String:
                    continuation.resume(returning: URL(string: string))
                default:
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    private static func loadText(from provider: NSItemProvider) async -> String? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { item, _ in
                switch item {
                case let string as String:
                    continuation.resume(returning: string)
                case let url as URL:
                    continuation.resume(returning: url.absoluteString)
                case let data as Data:
                    continuation.resume(returning: String(data: data, encoding: .utf8))
                default:
                    continuation.resume(returning: nil)
                }
            }
        }
    }
}
