import SwiftUI
import UIKit
import WidgetKit

extension AppDelegate {
    /// Process start: serve a share the Share Extension couldn't open the app for, whenever the
    /// app next comes to the front.
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        MainActor.assumeIsolated {
            SharedLinkInbox.shared.start()
            WidgetLanguageMirror.shared.start()
            #if DEBUG
            SystemGalleryPresenter.shared.startIfRequested()
            #endif
        }
        return true
    }
}

/// Serves ``SharedLinkHandoff``'s waiting link through the app's own link handling.
@MainActor
final class SharedLinkInbox {
    static let shared = SharedLinkInbox()
    private var observer: NSObjectProtocol?

    func start() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { _ = SharedLinkInbox.shared.drain() }
        }
    }

    /// Opens the waiting share, if any. Returns whether one was served.
    @discardableResult
    func drain(defaults: UserDefaults? = SharedLinkHandoff.sharedDefaults, model: AppModel? = nil) -> Bool {
        // Built here if the window's hasn't been yet, the way a widget button or Siri would.
        guard let model = model ?? SystemAppAccess.model(), let url = SharedLinkHandoff.take(from: defaults) else { return false }
        model.open(url)
        return true
    }
}

/// Copies the in-app language into the App Group so the widget follows it (the widget process
/// can't read the app's own defaults), and redraws the widgets when it changes.
@MainActor
final class WidgetLanguageMirror {
    static let shared = WidgetLanguageMirror()
    private var observer: NSObjectProtocol?

    func start() {
        guard observer == nil else { return }
        sync()
        // Posted in this process whenever its standard defaults change (LanguageBundle writes there).
        observer = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { _ = WidgetLanguageMirror.shared.sync() }
        }
    }

    /// Writes the app's language to `group` when it differs; returns whether it did.
    @discardableResult
    func sync(from app: UserDefaults = .standard, to group: UserDefaults? = NowPlayingSnapshot.sharedDefaults, reload: Bool = true) -> Bool {
        guard let group else { return false }
        let key = SharedStrings.languageOverrideKey
        let code = app.string(forKey: key)
        guard group.string(forKey: key) != code else { return false }
        group.set(code, forKey: key)
        if reload { WidgetCenter.shared.reloadAllTimelines() }
        return true
    }
}

#if DEBUG
/// `-systemGallery` (debug builds): lays the Home Screen widgets out over the app in every state,
/// for screenshots — the simulator can't be scripted to place a widget.
@MainActor
final class SystemGalleryPresenter {
    static let shared = SystemGalleryPresenter()
    private var window: UIWindow?
    private var observer: NSObjectProtocol?

    func startIfRequested() {
        guard ProcessInfo.processInfo.arguments.contains("-systemGallery") else { return }
        observer = NotificationCenter.default.addObserver(forName: UIScene.didActivateNotification, object: nil, queue: .main) { note in
            MainActor.assumeIsolated {
                guard let scene = note.object as? UIWindowScene else { return }
                SystemGalleryPresenter.shared.present(on: scene)
            }
        }
        // The window scene may already be active by the time the observer is in place.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            MainActor.assumeIsolated {
                let scene = UIApplication.shared.connectedScenes
                    .compactMap { $0 as? UIWindowScene }
                    .first { $0.activationState == .foregroundActive }
                if let scene { SystemGalleryPresenter.shared.present(on: scene) }
            }
        }
    }

    private func present(on scene: UIWindowScene) {
        guard window == nil else { return }
        let window = UIWindow(windowScene: scene)
        window.windowLevel = .alert + 1
        window.rootViewController = UIHostingController(rootView: SystemWidgetGallery())
        window.makeKeyAndVisible()
        self.window = window
    }
}
#endif

#if DEBUG
/// Every widget, with and without a track, as the Home Screen would draw them (the debug gallery,
/// and the render tests). Demo data: debug builds only, so it never compiles into Release — the
/// render tests in VibraMusicTests/System build in Debug, so they still see it.
struct SystemWidgetGallery: View {
    var snapshot: NowPlayingSnapshot? = SystemWidgetGallery.sampleSnapshot
    var art: WidgetArt? = SystemWidgetGallery.sampleArt

    static var sampleSnapshot: NowPlayingSnapshot {
        NowPlayingSnapshot(videoId: "5NV6Rdv1a3I", title: "Get Lucky", artist: "Daft Punk, Pharrell Williams", albumName: "Random Access Memories",
                           isPlaying: true, isLiked: true, shuffleEnabled: true, repeatMode: "OFF", hasNext: true, hasPrevious: false,
                           positionMs: 0, durationMs: 248_000, updatedAt: Date())
    }

    /// A made-up cover (warm gradient with a disc), so the blur and scrim have something to show.
    static var sampleArt: WidgetArt? {
        let size = CGSize(width: 480, height: 480)
        let image = UIGraphicsImageRenderer(size: size).image { context in
            let colors = [UIColor(red: 0.98, green: 0.55, blue: 0.2, alpha: 1).cgColor, UIColor(red: 0.55, green: 0.1, blue: 0.45, alpha: 1).cgColor]
            let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: [0, 1])!
            context.cgContext.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: size.width, y: size.height), options: [])
            UIColor(white: 1, alpha: 0.85).setFill()
            context.cgContext.fillEllipse(in: CGRect(x: 120, y: 80, width: 240, height: 240))
            UIColor(red: 0.1, green: 0.05, blue: 0.2, alpha: 1).setFill()
            context.cgContext.fillEllipse(in: CGRect(x: 215, y: 175, width: 50, height: 50))
        }
        return WidgetArt.make(from: image)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 18) {
                    CompactWidgetView(snapshot: snapshot, art: art, canvas: .inline).frame(width: 158, height: 158)
                    CompactWidgetView(snapshot: nil, art: nil, canvas: .inline).frame(width: 158, height: 158)
                }
                WideWidgetView(snapshot: snapshot, art: art, canvas: .inline).frame(width: 338, height: 158)
                PillWidgetView(snapshot: snapshot, art: art, canvas: .inline).frame(width: 338, height: 158)
                WideWidgetView(snapshot: nil, art: nil, canvas: .inline).frame(width: 338, height: 158)
            }
            .padding(.horizontal, 27)
            .padding(.vertical, 60)
            .frame(maxWidth: .infinity)
        }
        .background(
            LinearGradient(colors: [Color(red: 0.16, green: 0.3, blue: 0.55), Color(red: 0.45, green: 0.2, blue: 0.5)], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
        )
    }
}
#endif
