import AppKit
import CoreGraphics
import Foundation
import LumaWallCore
import Testing

/// Display topology invariants against the live screen list. Assertions hold
/// for any display count (including zero headless screens) — no hardcoded
/// geometry, so the tests stay valid on every machine.
@Suite(.serialized)
@MainActor
struct DisplayCoordinatorTests {
    @Test func refreshMirrorsLiveScreens() {
        let coordinator = DisplayCoordinator()
        let displays = coordinator.refresh()
        // compactMap may drop invalid entries, so count is bounded — never more.
        #expect(displays.count <= NSScreen.screens.count)
        #expect(coordinator.displays.count == displays.count)
    }

    @Test func everyDisplayRoundTripsByStableID() {
        let coordinator = DisplayCoordinator()
        for display in coordinator.refresh() {
            #expect(coordinator.display(id: display.displayID) == display)
            #expect(coordinator.screen(for: display.displayID) != nil)
        }
    }

    @Test func stableIDsAreDeterministic() {
        for screen in NSScreen.screens {
            #expect(DisplayCoordinator.stableID(for: screen) == DisplayCoordinator.stableID(for: screen))
        }
    }

    @Test func mainDisplayIsPrimaryOrFirst() {
        let coordinator = DisplayCoordinator()
        let displays = coordinator.refresh()
        if displays.isEmpty {
            #expect(coordinator.mainDisplay() == nil)
        } else {
            let main = coordinator.mainDisplay()
            #expect(main == displays.first(where: \.isMain) ?? displays.first)
        }
    }

    @Test func unknownDisplayIDFindsNothing() {
        let coordinator = DisplayCoordinator()
        _ = coordinator.refresh()
        let ghost = DisplayID(rawValue: "no-such-display")
        #expect(coordinator.display(id: ghost) == nil)
        #expect(coordinator.screen(for: ghost) == nil)
    }

    @Test func describedDisplaysHaveSaneGeometry() {
        let coordinator = DisplayCoordinator()
        for display in coordinator.refresh() {
            #expect(display.frame.width > 0 && display.frame.height > 0)
            #expect(display.scale > 0)
            #expect(display.cgDisplayID != 0)
            #expect(abs(display.pixelSize.width - display.frame.width * display.scale) < 1)
            #expect(abs(display.pixelSize.height - display.frame.height * display.scale) < 1)
        }
    }

    @Test func displaysAreHashableAndIdentifiable() {
        let coordinator = DisplayCoordinator()
        let displays = coordinator.refresh()
        for display in displays {
            #expect(display.id == display.displayID)
        }
        // Deduplication by stable ID works (hash uses displayID only).
        #expect(Set(displays).count == Set(displays.map(\.displayID)).count)
    }

    @Test func screenParameterNotificationRefreshesWithoutCrashing() async throws {
        let coordinator = DisplayCoordinator()
        _ = coordinator.refresh()
        NotificationCenter.default.post(
            name: NSApplication.didChangeScreenParametersNotification, object: nil
        )
        // The observer hops through a Task; allow it to run, then verify the
        // coordinator is still consistent (no assertion on change itself).
        try await Task.sleep(for: .milliseconds(200))
        #expect(coordinator.displays.count == coordinator.refresh().count)
    }
}
