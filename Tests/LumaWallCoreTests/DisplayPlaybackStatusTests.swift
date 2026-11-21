import Foundation
import Testing

@testable import LumaWallCore

struct DisplayPlaybackStatusTests {
    @Test func snapshotRoundTripsAndSortsByDisplay() throws {
        let snapshot = PlaybackStatusSnapshot(statuses: [
            DisplayPlaybackStatus(displayID: 9, state: .paused, reason: .covered),
            DisplayPlaybackStatus(displayID: 3, state: .playing, reason: .batteryTier, copy: .p1080, frameRate: 30),
        ])
        #expect(snapshot.statuses.map(\.displayID) == [3, 9])
        let decoded = PlaybackStatusSnapshot.decode(try snapshot.encoded())
        #expect(decoded == snapshot)
        #expect(decoded?.status(forDisplay: 9)?.reason == .covered)
    }

    @Test func garbageAndOtherVersionsDecodeToNil() throws {
        #expect(PlaybackStatusSnapshot.decode(Data("nope".utf8)) == nil)
        var future = PlaybackStatusSnapshot(statuses: [])
        future.version = 99
        #expect(PlaybackStatusSnapshot.decode(try future.encoded()) == nil)
    }

    @Test func copiesAreNamedFromTheirFile() {
        #expect(PlaybackCopy(filename: "Wallpaper.qhd.mov") == .p1440)
        #expect(PlaybackCopy(filename: "Wallpaper.reduced.mov") == .p1080)
        #expect(PlaybackCopy(filename: "Wallpaper.minimal.mov") == .p720)
        #expect(PlaybackCopy(filename: "Wallpaper.mov") == .full)
        #expect(PlaybackCopy(filename: "anything.mp4") == .full)
    }

    @Test func summariesNameStateCopyRateAndReason() {
        let playing = DisplayPlaybackStatus(displayID: 1, state: .playing, copy: .full, frameRate: 60)
        #expect(playing.summary == "Playing · Full · 60 fps")
        #expect(playing.headline == "Playing")
        let battery = DisplayPlaybackStatus(
            displayID: 1, state: .playing, reason: .batteryTier, copy: .p1080, frameRate: 30)
        #expect(battery.summary == "Playing · 1080p · 30 fps · on battery")
        #expect(battery.headline == "Playing lighter")
        let paused = DisplayPlaybackStatus(displayID: 1, state: .paused, reason: .gameMode, copy: .full, frameRate: 60)
        #expect(paused.summary == "Paused · Game Mode is on")
        let overlay = DisplayPlaybackStatus(displayID: 1, state: .paused, reason: .userPause, engine: .overlay)
        #expect(overlay.summary == "Paused · paused by you · Safe mode")
    }

    @Test func unknownCopyDropsTheDetail() {
        #expect(DisplayPlaybackStatus(displayID: 1, state: .playing).copyDetail == nil)
        #expect(DisplayPlaybackStatus(displayID: 1, state: .playing, frameRate: 0).copyDetail == nil)
    }

    @Test func accessibilityLabelIsASentence() {
        let status = DisplayPlaybackStatus(
            displayID: 1, state: .playing, reason: .thermal, copy: .p720, frameRate: 30)
        #expect(
            status.accessibilityLabel(displayName: "Studio Display")
                == "Studio Display: playing the 720p copy at 30 frames per second, Mac is running hot")
    }

    @Test func everyReasonHasAPhrase() {
        for reason in PlaybackStatusReason.allCases { #expect(!reason.phrase.isEmpty) }
    }

    @Test func overlayTiersMapToStateAndEngine() {
        let full = DisplayPlaybackStatus(displayID: 1, overlayTier: .full, reason: nil)
        #expect(full.state == .playing && full.engine == .overlay && full.copy == .full)
        let battery = DisplayPlaybackStatus(displayID: 1, overlayTier: .reduced, reason: .batteryTier)
        #expect(battery.state == .playing && battery.copy == nil)
        #expect(battery.summary == "Playing · on battery · Safe mode")
        let still = DisplayPlaybackStatus(displayID: 1, overlayTier: .staticFrame, reason: .batteryStatic)
        #expect(still.state == .paused)
        #expect(DisplayPlaybackStatus(displayID: 1, overlayTier: .paused, reason: .locked).state == .paused)
    }
}
