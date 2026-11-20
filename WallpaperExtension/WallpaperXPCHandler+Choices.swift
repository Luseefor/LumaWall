import AppKit
import AVFoundation
import CoreMedia
import os
import QuartzCore

extension WallpaperXPCHandler {
    func removeChoiceRequest(withChoiceRequest request: Any?, reply: @escaping @Sendable ((any Error)?) -> Void) {
        markServed()
        nonisolated(unsafe) let unsafeRequest = request
        nonisolated(unsafe) let handler = self
        Lifecycle.queue.async { handler.removeChoiceRequestBody(request: unsafeRequest, reply: reply) }
    }

    private func removeChoiceRequestBody(request: Any?, reply: @escaping @Sendable ((any Error)?) -> Void) {
        extensionLog("=== REMOVE CHOICE REQUEST ===")

        // Settings lists choices under the provider ID SettingsProvider uses.
        let ownProvider = Bundle.main.bundleIdentifier ?? "app.lumawall.personal.wallpaper"
        let target = request.map {
            ChoiceRemoval.target(in: $0, ownProvider: ownProvider) { VideoLibrary.shared.entry(for: $0) != nil }
        }
        guard case let .remove(videoID) = target else {
            if case let .refuse(reason) = target {
                extensionLog("  [Remove] Refused: \(reason)")
            } else {
                extensionLog("  [Remove] Refused: no request")
            }
            if let request, verboseLoggingEnabled { dumpMirror(request, label: "removeRequest") }
            reply(nil)
            return
        }

        extensionLog("  [Remove] Removing video: \(videoID)")

        // Remove from library (deletes files + metadata)
        VideoLibrary.shared.removeVideo(id: videoID)

        // Tear down only the contexts actually using this video. The video is gone
        // from the library, so these slots are genuinely dead (not a reuse). Other
        // displays may be playing different videos and must keep running.
        let removedKeys = WallpaperState.shared.removeContexts(forVideoID: videoID)
        for key in removedKeys {
            cancelTeardown(for: key)
            failHeldReplies(for: key)
        }
        if !removedKeys.isEmpty {
            if WallpaperState.shared.currentVideoID == videoID {
                WallpaperState.shared.currentVideoID = nil
                WallpaperState.shared.cachedThumbnailURL = nil
            }
            WallpaperPrefs.shared.updateCurrentVideo()
            extensionLog("  [Remove] Stopped \(removedKeys.count) renderer(s) for removed video")
        }

        // Invalidate Agent snapshots so Settings refreshes
        if let proxy = agentProxy {
            proxy.invalidateSnapshots { error in
                if let error {
                    extensionLog("  [Remove] invalidateSnapshots error: \(LogRedaction.describe(error))")
                }
            }
        }

        reply(nil)
    }

    func selectedChoicesDidChange(for id: Any?, reply: @escaping @Sendable ((any Error)?) -> Void) {
        markServed()
        nonisolated(unsafe) let unsafeID = id
        nonisolated(unsafe) let handler = self
        Lifecycle.queue.async { handler.selectedChoicesDidChangeBody(id: unsafeID, reply: reply) }
    }

    private func selectedChoicesDidChangeBody(id: Any?, reply: @escaping @Sendable ((any Error)?) -> Void) {
        extensionLog("=== SELECTED CHOICES DID CHANGE ===")

        // Extract the choice identifier from the WallpaperChoiceID
        var choiceIdentifier: String?
        if let idObj = id as? NSObject {
            let mirror = Mirror(reflecting: idObj)
            for child in mirror.children {
                let desc = String(describing: child.value)
                // Look for the identifier field which contains our video UUID
                if let range = desc.range(of: "identifier: \"") {
                    let after = desc[range.upperBound...]
                    if let endQuote = after.firstIndex(of: "\"") {
                        choiceIdentifier = String(after[..<endQuote])
                    }
                }
            }
        }

        // Native automations keep their choice id on the display context and resolve
        // the currently appropriate concrete video independently.
        if ExtensionAutomationLibrary.isAutomationChoice(choiceIdentifier), let choiceIdentifier {
            extensionLog("=== CHOICE CHANGED === automation \(choiceIdentifier)")
            if let pick = AutomationController.shared.resolveChoice(choiceIdentifier) {
                WallpaperState.shared.currentVideoID = pick
                WallpaperState.shared.cachedThumbnailURL = nil
                WallpaperPrefs.shared.updateCurrentVideo()
            }
            if let proxy = agentProxy {
                proxy.invalidateSnapshots { error in
                    if let error { extensionLog("  [Choice] invalidateSnapshots error: \(LogRedaction.describe(error))") }
                }
            }
            reply(nil)
            return
        }

        // The shuffle choice has no fixed video to record. Resolve the current pick for
        // the menu-bar UI and refresh snapshots. The acquire that follows activates
        // rotation and does the rendering.
        if ExtensionPlaylistLibrary.isShuffleChoice(choiceIdentifier), let choiceIdentifier {
            extensionLog("=== CHOICE CHANGED === shuffle \(choiceIdentifier)")
            if let pick = ShuffleController.shared.resolveChoice(choiceIdentifier) {
                WallpaperState.shared.currentVideoID = pick
                WallpaperState.shared.cachedThumbnailURL = nil
                WallpaperPrefs.shared.updateCurrentVideo()
            }
            if let proxy = agentProxy {
                proxy.invalidateSnapshots { error in
                    if let error {
                        extensionLog("  [Choice] invalidateSnapshots error: \(LogRedaction.describe(error))")
                    }
                }
            }
            reply(nil)
            return
        }

        guard let videoID = choiceIdentifier else {
            extensionLog("selectedChoicesDidChange: unknown choice \(String(describing: choiceIdentifier))")
            reply(nil)
            return
        }

        guard VideoLibrary.shared.entry(for: videoID) != nil else {
            extensionLog("selectedChoicesDidChange: unknown video \(videoID)")
            reply(nil)
            return
        }

        extensionLog("=== CHOICE CHANGED === videoID: \(videoID)")

        // Track the last user-picked video (for menu-bar UI / new-acquire fallback).
        // The XPC API does NOT tell us which display this choice is for, only that
        // the user picked it. We can't safely touch any renderer here; doing so used
        // to flip the wrong display, because stopping all renderers forced macOS to
        // re-acquire every display, and the racing acquires would pick up the wrong
        // per-context choiceConfiguration. macOS issues `invalidate(oldID)` and
        // `acquire(newID)` for the affected display on its own; let it.
        WallpaperState.shared.currentVideoID = videoID
        WallpaperState.shared.cachedThumbnailURL = nil
        WallpaperPrefs.shared.updateCurrentVideo()

        // Invalidate Agent snapshots so the picker re-fetches with the new video.
        if let proxy = agentProxy {
            proxy.invalidateSnapshots { error in
                if let error {
                    extensionLog("  [Choice] invalidateSnapshots error: \(LogRedaction.describe(error))")
                }
            }
        }

        reply(nil)
    }

    func invokeContextMenuAction(withMenuItemID menuItemID: Any?, groupItemID _: Any?, reply: @escaping @Sendable ((any Error)?) -> Void) {
        let identifier = (menuItemID as? String) ?? String(describing: menuItemID ?? "nil")
        extensionLog("=== CONTEXT MENU ACTION === identifier: \(identifier)")

        if CompanionLaunch.launchesCompanion(identifier) {
            switch CompanionLaunch.verifiedCompanion() {
            case let .success(app):
                extensionLog("  Opening the companion app")
                NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration()) { _, error in
                    if let error { extensionLog("  [Companion] Open failed: \(error)") }
                }
            case let .failure(reason):
                extensionLog("  [Companion] Not opening the companion app: \(reason)")
            }
        }

        reply(nil)
    }
}
