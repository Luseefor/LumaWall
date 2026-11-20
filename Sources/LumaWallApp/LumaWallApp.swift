import AppKit
import LumaWallCore
import SwiftUI

#if LUMAWALL_TEST_HOST
    // Playback tests create their own sessions and temporary media. Keep the test
    // host from restoring real wallpapers or opening the user's library stores.
    @main
    struct LumaWallTestHost: App {
        var body: some Scene {
            WindowGroup { Color.clear.frame(width: 32, height: 32) }
        }
    }
#else
    @main
    struct LumaWallApp: App {
        @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
        @Environment(\.openWindow) private var openWindow
        @State private var model = AppModel()

        var body: some Scene {
            WindowGroup("LumaWall", id: "main") {
                RootView(model: model)
                    .frame(minWidth: 1_080, minHeight: 700)
            }
            .defaultSize(width: 1_280, height: 840)
            .windowStyle(.hiddenTitleBar)
            .windowToolbarStyle(.unifiedCompact)
            .commands {
                CommandGroup(replacing: .appInfo) {
                    Button("About LumaWall") {
                        NSApp.setActivationPolicy(.regular)
                        NSApp.activate(ignoringOtherApps: true)
                        openWindow(id: AboutWindow.id)
                    }
                    Divider()
                    Button("Check for Updates…") {
                        NSWorkspace.shared.open(AboutLinks.releases)
                    }
                }
            }

            Window("About LumaWall", id: AboutWindow.id) {
                AboutView()
            }
            .windowResizability(.contentSize)
            .windowStyle(.hiddenTitleBar)
            .windowBackgroundDragBehavior(.enabled)

            MenuBarExtra {
                MenuBarPopover(model: model)
            } label: {
                Image(nsImage: MenuBarIcon.image(badge: model.activePlaylistID != nil))
            }
            .menuBarExtraStyle(.window)
        }
    }
#endif

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Set by `AppModel`: writes pending energy samples before the app quits.
    @MainActor static var flushBeforeTermination: (@MainActor () async -> Void)?

    /// Defers quitting until pending work is flushed, without blocking the
    /// main thread; the flush has its own deadline.
    nonisolated func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let flush = MainActor.assumeIsolated { Self.flushBeforeTermination }
        guard let flush else { return .terminateNow }
        Task { @MainActor in
            await flush()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    nonisolated func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        DispatchQueue.main.async { sender.setActivationPolicy(.accessory) }
        return false
    }

    nonisolated func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        DispatchQueue.main.async { sender.setActivationPolicy(.regular) }
        return true
    }
}

struct RootView: View {
    @Bindable var model: AppModel

    var body: some View {
        ZStack {
            AtmosphereBackground()
            VStack(spacing: 0) {
                AppChrome(model: model)
                Rectangle().fill(Theme.line).frame(height: 1)
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .modifier(NativeModeDisclosure(model: model))
        }
        .preferredColorScheme(.dark)
        .tint(Theme.accent)
        .dropDestination(for: URL.self) { urls, _ in
            model.importVideos(urls); return true
        }
        .alert(
            model.activeAlert?.title ?? "",
            isPresented: Binding(
                get: { model.activeAlert != nil },
                set: { if !$0 { model.acknowledgeAlert() } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.activeAlert?.message ?? "")
        }
        .sheet(
            item: Binding(
                get: { model.topSheet },
                set: { model.setTopSheet($0) }
            )
        ) { route in
            switch route {
            case .preview(let asset): PreviewSheet(model: model, asset: asset)
            case .assign(let display): AssignSheet(model: model, display: display)
            case .automation(let slot): AutomationPickSheet(model: model, slot: slot)
            case .playlistEditor: PlaylistEditorSheet(model: model)
            }
        }
        .overlay {
            if model.isImporting || model.isApplying {
                BusyOverlay(text: model.isImporting ? "Preparing wallpaper…" : "Applying to desktop…")
            }
        }
        .onAppear { model.refreshDisplays() }
        .onAppear {
            NSApp.setActivationPolicy(.regular)
            NSApp.keyWindow?.identifier = NSUserInterfaceItemIdentifier("LumaWallMainWindow")
        }
    }

    @ViewBuilder private var content: some View {
        switch model.section {
        case .home: HomePage(model: model)
        case .library: LibraryPage(model: model)
        case .displays: DisplaysPage(model: model)
        case .settings: SettingsPage(model: model)
        }
    }
}
