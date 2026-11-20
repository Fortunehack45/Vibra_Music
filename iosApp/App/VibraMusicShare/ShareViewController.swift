import UIKit

/// The share-sheet entry: "Vibra Music" under a YouTube / YouTube Music link or text shared from
/// another app. Ports MainActivity's `ACTION_SEND` handling — Android shows no UI of its own for a
/// share, it just opens the app on the right screen — so this has no interface either: it reads the
/// first link (or the text), hands it to the app through ``SharedLinkHandoff`` and finishes.
final class ShareViewController: UIViewController {
    private var handled = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !handled else { return }
        handled = true
        Task { @MainActor in
            let (link, text) = await SharedLinkHandoff.readShared(extensionContext?.inputItems as? [NSExtensionItem] ?? [])
            guard let url = SharedLinkHandoff.appURL(link: link, text: text) else {
                extensionContext?.completeRequest(returningItems: nil)
                return
            }
            let opened = await openApp(url)
            // Refused (or no way to ask): leave it in the App Group for the app to serve when it is
            // next opened. Only then, so a share that did open the app isn't served twice.
            if !opened { SharedLinkHandoff.save(url) }
            extensionContext?.completeRequest(returningItems: nil)
        }
    }

    /// A share extension has no `open(_:)` of its own (`NSExtensionContext.open` is for Today
    /// widgets), so the request goes up the responder chain to the hosting application object.
    private func openApp(_ url: URL) async -> Bool {
        let selector = NSSelectorFromString("openURL:options:completionHandler:")
        var responder: UIResponder? = self
        while let current = responder {
            if current !== self, current.responds(to: selector), NSStringFromClass(type(of: current)).contains("Application") {
                typealias OpenURL = @convention(c) (AnyObject, Selector, URL, NSDictionary, (@convention(block) (Bool) -> Void)?) -> Void
                let open = unsafeBitCast(current.method(for: selector), to: OpenURL.self)
                return await withCheckedContinuation { continuation in
                    open(current, selector, url, NSDictionary()) { success in continuation.resume(returning: success) }
                }
            }
            responder = current.next
        }
        return false
    }
}
