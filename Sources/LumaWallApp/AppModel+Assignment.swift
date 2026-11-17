import AppKit
import CoreGraphics
import Darwin
import IOKit.ps
import LumaWallCore
import Observation
import UniformTypeIdentifiers

extension AppModel {
    func apply(
        _ asset: WallpaperAsset,
        to displayID: DisplayID? = nil,
        composition: DisplayComposition = .init(),
        continuingPlaylist: Bool = false
    ) {
        isApplying = true
        if !continuingPlaylist { stopPlaylistRotation() }
        Task {
            do {
                if let displayID {
                    try await engine.apply(asset, to: displayID, composition: composition)
                } else if let main = displayCoordinator.mainDisplay() {
                    try await engine.apply(asset, to: main.displayID, composition: composition)
                }
                try? await store.recordApply(id: asset.id)
                try? await recentsStore.push(asset.id)
                await reload()
                applyPlaybackPolicy()
            } catch {
                present("Couldn't apply wallpaper", error.localizedDescription)
            }
            isApplying = false
        }
    }

    func composition(on display: ConnectedDisplay) -> DisplayComposition {
        engine.composition(on: display.displayID)
    }

    func applyToAll(_ asset: WallpaperAsset, continuingPlaylist: Bool = false) {
        isApplying = true
        if !continuingPlaylist { stopPlaylistRotation() }
        Task {
            do {
                try await engine.applyToAll(asset)
                try? await store.recordApply(id: asset.id)
                try? await recentsStore.push(asset.id)
                await reload()
                applyPlaybackPolicy()
            } catch {
                present("Couldn't apply wallpaper", error.localizedDescription)
            }
            isApplying = false
        }
    }

    func spanAcrossAllDisplays(_ asset: WallpaperAsset) {
        isApplying = true
        stopPlaylistRotation()
        Task {
            do {
                try await engine.applySpanning(asset)
                try? await store.recordApply(id: asset.id)
                try? await recentsStore.push(asset.id)
                await reload()
                applyPlaybackPolicy()
            } catch {
                present("Couldn't span wallpaper", error.localizedDescription)
            }
            isApplying = false
        }
    }

    func reapplyActive() {
        engine.reapplyAssignments()
        applyPlaybackPolicy()
    }

    func clearDisplay(_ display: ConnectedDisplay) {
        Task {
            try? await engine.clear(display.displayID)
            refreshActive()
            applyPlaybackPolicy()
        }
    }

    func togglePause() {
        userPaused.toggle()
        UserDefaults.standard.set(userPaused, forKey: "lumawall.userPaused")
        applyPlaybackPolicy()
    }

    func togglePause(on display: ConnectedDisplay) {
        if pausedDisplayIDs.contains(display.displayID) {
            pausedDisplayIDs.remove(display.displayID)
        } else {
            pausedDisplayIDs.insert(display.displayID)
        }
        UserDefaults.standard.set(pausedDisplayIDs.map(\.rawValue), forKey: "lumawall.pausedDisplayIDs")
        applyPlaybackPolicy()
    }

    func isDisplayPaused(_ display: ConnectedDisplay) -> Bool {
        userPaused || pausedDisplayIDs.contains(display.displayID) || engine.tier(on: display.displayID) == .paused
    }

    func setPauseWhenObscured(_ enabled: Bool) {
        pauseWhenObscured = enabled
        UserDefaults.standard.set(enabled, forKey: "lumawall.pauseWhenObscured")
        applyPlaybackPolicy()
    }

    func setPauseOnLock(_ enabled: Bool) {
        pauseOnLock = enabled
        UserDefaults.standard.set(enabled, forKey: "lumawall.pauseOnLock")
        applyPlaybackPolicy()
    }

    func setHideDesktopVideo(_ enabled: Bool) {
        hideDesktopVideo = enabled
        UserDefaults.standard.set(enabled, forKey: "lumawall.hideDesktopVideo")
        applyPlaybackPolicy()
    }

    func setPowerProfile(_ profile: PowerProfile) {
        powerProfile = profile
        UserDefaults.standard.set(profile.rawValue, forKey: "lumawall.powerProfile")
        applyPlaybackPolicy()
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            launchAtLogin = try LaunchAtLogin.setEnabled(enabled)
        } catch {
            launchAtLogin = LaunchAtLogin.isEnabled
            present("Launch at Login", error.localizedDescription)
        }
    }

    func clearMemoryCache() {
        CacheCleaner.clearMemory()
        engine.releaseWorkingMemory()
        applyPlaybackPolicy()
        refreshStats()
        present("RAM", "Released wallpaper decoders and in-memory caches.")
    }

    func clearDiskCache() {
        Task {
            do {
                let removed = try await CacheCleaner.clearDisk(preservingLibraryRoot: store.rootURL)
                refreshStats()
                present("Cache", removed == 0 ? "No cache files to remove." : "Cleared \(removed) cache items.")
            } catch {
                present("Cache", error.localizedDescription)
            }
        }
    }
}
