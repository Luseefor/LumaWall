import Foundation

/// Pure display-topology helpers shared by both wallpaper hosts.
///
/// Monitor add/remove races are the classic source of "half the screen" and
/// "stuck overlay" glitches: restores only re-applied *stored* assignments,
/// so a freshly attached display had no assignment at all (blank/system
/// wallpaper), while sessions for removed displays lingered. Centralizing the
/// set math here keeps both hosts consistent and testable.
public enum DisplayTopology {
    /// Assignments to create for connected displays that have no stored
    /// assignment (e.g. a freshly attached monitor). They inherit the main
    /// display's wallpaper and composition, falling back to the first enabled
    /// assignment that names a wallpaper, so a new monitor shows the current
    /// wallpaper instead of the system default.
    ///
    /// Assignments for disconnected displays are intentionally left untouched,
    /// a reattached display resumes where it was.
    ///
    /// Returns empty when every connected display is covered or when there is
    /// nothing enabled to inherit from.
    public static func inheritedAssignments(
        stored: [DisplayAssignment],
        connectedIDs: Set<DisplayID>,
        mainDisplayID: DisplayID?
    ) -> [DisplayAssignment] {
        let covered = Set(stored.map(\.displayID))
        let missing = connectedIDs.subtracting(covered)
        guard !missing.isEmpty else { return [] }
        let enabled = stored.filter(\.isEnabled)
        let donor = mainDisplayID.flatMap { id in
            enabled.first { $0.displayID == id && $0.wallpaperID != nil }
        } ?? enabled.first { $0.wallpaperID != nil }
        guard let donor, let wallpaperID = donor.wallpaperID else { return [] }
        return missing.sorted { $0.rawValue < $1.rawValue }.map {
            DisplayAssignment(
                displayID: $0,
                wallpaperID: wallpaperID,
                composition: donor.composition,
                isEnabled: true
            )
        }
    }
}
