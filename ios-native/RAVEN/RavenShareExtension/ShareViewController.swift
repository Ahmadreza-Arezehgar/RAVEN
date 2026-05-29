//
//  ShareViewController.swift
//  RavenShareExtension
//
//  (2026-05-15 — round 8) iOS Share Extension entry point. Apple
//  routes any Share button → RAVEN tap into this controller. We
//  collect every attachment the host app handed us, persist them
//  into a shared App Group container, then deep-link the host app
//  with `raven://share` so the user lands in the recipient picker.
//
//  Why we use a shared container instead of XPC:
//    • The extension and the host app are sandboxed separately;
//      App Groups are the official Apple-blessed channel.
//    • The host app reads from the container on launch, finds the
//      pending payload, and inserts it into the chat the user picks.
//    • If the user kills RAVEN before opening it, the payload sits
//      in the container until next launch (or expires after 24h).
//
//  The UI subclass is `SLComposeServiceViewController` so we get
//  Apple's standard text-input + recipient-picker chrome. Recipient
//  selection lives inside RAVEN proper — the extension only grabs
//  the bytes + handoff URL.

import UIKit
import Social
import UniformTypeIdentifiers

class ShareViewController: SLComposeServiceViewController {

    /// App Group identifier — must match the entitlement in both this
    /// target's `.entitlements` file and the host RAVEN target's.
    /// Add `group.app.raven.shared` in the Apple Developer portal +
    /// the project's Capabilities tab if it's not there already.
    private let appGroup = "group.app.raven.shared"
    private let pendingShareKey = "raven.pendingShare.v1"

    override func isContentValid() -> Bool {
        // Always allow the user to post — we accept any combination
        // of text + attachments. The empty case is handled by the
        // host app (it just shows "nothing to share" if both are nil).
        return true
    }

    override func didSelectPost() {
        let captionText = self.contentText ?? ""
        Task { [weak self] in
            await self?.persistAndHandoff(caption: captionText)
        }
    }

    override func configurationItems() -> [Any]! {
        // No "Choose chat" picker here — keeps the extension tight.
        // The host app's recipient picker takes over after handoff.
        return []
    }

    // MARK: - Persistence

    /// Pull every attachment off the input items, copy them into the
    /// App Group container, and write a manifest so the host app
    /// can pick them up on launch. Finally, complete the request +
    /// deep-link RAVEN.
    private func persistAndHandoff(caption: String) async {
        var manifest: [[String: String]] = []
        var capturedText: String? = caption.isEmpty ? nil : caption

        guard let inputItems = self.extensionContext?.inputItems as? [NSExtensionItem] else {
            await complete()
            return
        }

        for item in inputItems {
            guard let providers = item.attachments else { continue }
            for provider in providers {
                if let entry = await persist(provider: provider) {
                    manifest.append(entry)
                }
                // If the host item ships with an inline text body
                // (Safari article excerpt, etc.) keep it as the
                // caption when the user didn't type one.
                if capturedText == nil, let item = item.attributedContentText?.string, !item.isEmpty {
                    capturedText = item
                }
            }
        }

        // Write the manifest into the App Group so RAVEN can pick it
        // up on next foreground.
        let payload: [String: Any] = [
            "version": 1,
            "createdAt": Date().timeIntervalSince1970,
            "caption": capturedText ?? "",
            "items": manifest
        ]
        if let defaults = UserDefaults(suiteName: appGroup) {
            defaults.set(payload, forKey: pendingShareKey)
            defaults.synchronize()
        }

        await complete()
    }

    /// Copy a single attachment into the App Group's tmp directory.
    /// Returns a manifest entry the host app can read back.
    private func persist(provider: NSItemProvider) async -> [String: String]? {
        // Try the most specific type first so a video isn't mis-saved
        // as a generic file.
        if provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier) {
            return await copyToContainer(provider: provider, type: UTType.movie, kind: "video")
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
            return await copyToContainer(provider: provider, type: UTType.image, kind: "image")
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.pdf.identifier) {
            return await copyToContainer(provider: provider, type: UTType.pdf, kind: "pdf")
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            return await copyToContainer(provider: provider, type: UTType.fileURL, kind: "file")
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
            return await loadAsString(provider: provider, type: UTType.url, kind: "url")
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
            return await loadAsString(provider: provider, type: UTType.plainText, kind: "text")
        }
        return nil
    }

    private func copyToContainer(provider: NSItemProvider, type: UTType, kind: String) async -> [String: String]? {
        return await withCheckedContinuation { cont in
            provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, error in
                guard let url, error == nil else {
                    cont.resume(returning: nil)
                    return
                }
                guard let dest = self.containerURL(for: url) else {
                    cont.resume(returning: nil)
                    return
                }
                try? FileManager.default.removeItem(at: dest)
                do {
                    try FileManager.default.copyItem(at: url, to: dest)
                    cont.resume(returning: [
                        "kind": kind,
                        "path": dest.path,
                        "originalName": url.lastPathComponent
                    ])
                } catch {
                    cont.resume(returning: nil)
                }
            }
        }
    }

    private func loadAsString(provider: NSItemProvider, type: UTType, kind: String) async -> [String: String]? {
        return await withCheckedContinuation { cont in
            provider.loadItem(forTypeIdentifier: type.identifier) { item, _ in
                if let url = item as? URL {
                    cont.resume(returning: ["kind": kind, "value": url.absoluteString])
                } else if let s = item as? String {
                    cont.resume(returning: ["kind": kind, "value": s])
                } else {
                    cont.resume(returning: nil)
                }
            }
        }
    }

    private func containerURL(for source: URL) -> URL? {
        guard let base = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup) else {
            return nil
        }
        let dir = base.appendingPathComponent("PendingShare")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let unique = "\(UUID().uuidString)_\(source.lastPathComponent)"
        return dir.appendingPathComponent(unique)
    }

    // MARK: - Completion

    @MainActor
    private func complete() async {
        // Open RAVEN with our handoff URL. iOS dispatches it through
        // `application(_:open:options:)` in `AppDelegate`; the host
        // reads the manifest from the App Group and presents the
        // recipient picker.
        if let url = URL(string: "raven://share/v1?source=extension") {
            // Walk the responder chain to call `open(_:)` since
            // extensions can't use `UIApplication.shared` directly.
            var responder: UIResponder? = self
            while let r = responder {
                if r.responds(to: NSSelectorFromString("openURL:")) {
                    _ = r.perform(NSSelectorFromString("openURL:"), with: url)
                    break
                }
                responder = r.next
            }
        }
        self.extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
    }
}
