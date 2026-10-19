import Foundation
import LumaWallCore
import Testing

struct DisplayTopologyTests {
    private func assignment(
        _ display: String,
        wallpaper: UUID? = UUID(),
        enabled: Bool = true
    ) -> DisplayAssignment {
        DisplayAssignment(
            displayID: DisplayID(rawValue: display),
            wallpaperID: wallpaper.map(WallpaperID.init(rawValue:)),
            composition: .init(),
            isEnabled: enabled
        )
    }

    @Test func newDisplayInheritsMainWallpaper() {
        let wallpaperID = UUID()
        let stored = [
            DisplayAssignment(
                displayID: DisplayID(rawValue: "main"),
                wallpaperID: WallpaperID(rawValue: wallpaperID),
                composition: .init(),
                isEnabled: true
            )
        ]
        let inherited = DisplayTopology.inheritedAssignments(
            stored: stored,
            connectedIDs: [DisplayID(rawValue: "main"), DisplayID(rawValue: "new")],
            mainDisplayID: DisplayID(rawValue: "main")
        )
        #expect(inherited.count == 1)
        #expect(inherited.first?.displayID.rawValue == "new")
        #expect(inherited.first?.wallpaperID?.rawValue == wallpaperID)
        #expect(inherited.first?.isEnabled == true)
    }

    @Test func fullyCoveredTopologyInheritsNothing() {
        let stored = [assignment("a"), assignment("b")]
        let inherited = DisplayTopology.inheritedAssignments(
            stored: stored,
            connectedIDs: [DisplayID(rawValue: "a"), DisplayID(rawValue: "b")],
            mainDisplayID: DisplayID(rawValue: "a")
        )
        #expect(inherited.isEmpty)
    }

    @Test func fallsBackToFirstEnabledWhenMainHasNone() {
        let wallpaperID = UUID()
        let stored = [
            assignment("main", wallpaper: nil),
            DisplayAssignment(
                displayID: DisplayID(rawValue: "other"),
                wallpaperID: WallpaperID(rawValue: wallpaperID),
                composition: .init(),
                isEnabled: true
            ),
        ]
        let inherited = DisplayTopology.inheritedAssignments(
            stored: stored,
            connectedIDs: [DisplayID(rawValue: "main"), DisplayID(rawValue: "other"), DisplayID(rawValue: "new")],
            mainDisplayID: DisplayID(rawValue: "main")
        )
        #expect(inherited.count == 1)
        #expect(inherited.first?.wallpaperID?.rawValue == wallpaperID)
    }

    @Test func nothingEnabledInheritsNothing() {
        let stored = [assignment("a", enabled: false)]
        let inherited = DisplayTopology.inheritedAssignments(
            stored: stored,
            connectedIDs: [DisplayID(rawValue: "a"), DisplayID(rawValue: "new")],
            mainDisplayID: DisplayID(rawValue: "a")
        )
        #expect(inherited.isEmpty)
    }

    @Test func disconnectedAssignmentsArePreserved() {
        // The helper only *adds* coverage for connected displays; pruning
        // disconnected entries is the caller's (non-)job so reconnects resume.
        let stored = [assignment("gone")]
        let inherited = DisplayTopology.inheritedAssignments(
            stored: stored,
            connectedIDs: [DisplayID(rawValue: "new")],
            mainDisplayID: nil
        )
        #expect(inherited.count == 1)
        #expect(inherited.first?.displayID.rawValue == "new")
        #expect(inherited.first?.wallpaperID == stored.first?.wallpaperID)
    }
}
