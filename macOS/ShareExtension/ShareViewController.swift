import AlexaKit
import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Entry point of the macOS share extension (Share menu in Music.app, Safari, ...).
/// Same UI as iOS: shows what will play, lets you pick the Echo, plays.
final class ShareViewController: NSViewController {
    override var nibName: NSNib.Name? { nil }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 560))
        preferredContentSize = NSSize(width: 420, height: 560)

        Task { @MainActor [weak self] in
            guard let self else { return }
            let (url, text) = await extractSharedContent()
            let model = ShareModel(service: AppEnvironment.service, sharedURL: url, sharedText: text)
            let root = ShareView(model: model) { [weak self] in
                self?.extensionContext?.completeRequest(returningItems: nil)
            }
            .frame(minWidth: 380, minHeight: 500)
            let host = NSHostingView(rootView: root)
            host.frame = view.bounds
            host.autoresizingMask = [.width, .height]
            view.addSubview(host)
        }
    }

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
                    // macOS often hands over URLs as bookmark-style data.
                    let url = URL(dataRepresentation: data, relativeTo: nil)
                        ?? String(data: data, encoding: .utf8).flatMap(URL.init(string:))
                    continuation.resume(returning: url)
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
