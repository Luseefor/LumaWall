import Foundation
import LumaWallCore
import Testing

/// Security tests for library path validation.
///
/// Every case asserts a specific outcome for a concrete attack or edge input —
/// never bare truthiness. Fixtures are inline literals, never production data.
struct PathSafetyTests {
    // MARK: - Entry IDs (happy + attack)

    @Test func validUUIDEntryIDIsAccepted() {
        #expect(PathSafety.isValidEntryID("550E8400-E29B-41D4-A716-446655440000"))
        #expect(PathSafety.isValidEntryID(UUID().uuidString))
    }

    @Test func traversalAndGarbageEntryIDsAreRejected() {
        #expect(!PathSafety.isValidEntryID(".."))
        #expect(!PathSafety.isValidEntryID("../videos"))
        #expect(!PathSafety.isValidEntryID("/etc/passwd"))
        #expect(!PathSafety.isValidEntryID(""))
        #expect(!PathSafety.isValidEntryID("not-a-uuid"))
        #expect(!PathSafety.isValidEntryID("550E8400-E29B-41D4-A716"))
        #expect(!PathSafety.isValidEntryID("550E8400-E29B-41D4-A716-446655440000 "))
    }

    // MARK: - Filename components (happy + attack)

    @Test func plainBasenamesAreAccepted() {
        #expect(PathSafety.isSafeComponent("wallpaper.mov"))
        #expect(PathSafety.isSafeComponent("variant_30fps.mp4"))
        #expect(PathSafety.isSafeComponent("metadata.json"))
        #expect(PathSafety.isSafeComponent("thumbnail.jpg"))
        #expect(PathSafety.isSafeComponent("My Vacation 2024.m4v"))
    }

    @Test func traversalSeparatorsAreRejected() {
        #expect(!PathSafety.isSafeComponent("../evil.mov"))
        #expect(!PathSafety.isSafeComponent("sub/dir.mov"))
        #expect(!PathSafety.isSafeComponent("..\\evil.mov"))
        #expect(!PathSafety.isSafeComponent("C:\\evil.mov"))
        #expect(!PathSafety.isSafeComponent("/absolute.mov"))
    }

    @Test func dotNamesEmptyAndControlCharactersAreRejected() {
        #expect(!PathSafety.isSafeComponent(""))
        #expect(!PathSafety.isSafeComponent("."))
        #expect(!PathSafety.isSafeComponent(".."))
        #expect(!PathSafety.isSafeComponent("evil\u{00}.mov"))
        #expect(!PathSafety.isSafeComponent("evil\u{1B}.mov"))
        #expect(!PathSafety.isSafeComponent("evil\u{7F}.mov"))
    }

    // MARK: - Containment gate

    @Test func descendantAndSelfAreContained() throws {
        let base = URL(fileURLWithPath: "/tmp/LumaWall-lib", isDirectory: true)
        #expect(PathSafety.contained(base, in: base))
        #expect(PathSafety.contained(
            base.appendingPathComponent("550E8400").appendingPathComponent("wallpaper.mov"),
            in: base
        ))
    }

    @Test func dotDotEscapeIsNotContained() {
        let base = URL(fileURLWithPath: "/tmp/LumaWall-lib", isDirectory: true)
        #expect(!PathSafety.contained(
            base.appendingPathComponent("..").appendingPathComponent("evil.mov"),
            in: base
        ))
        #expect(!PathSafety.contained(URL(fileURLWithPath: "/etc/passwd"), in: base))
    }

    @Test func siblingPrefixIsNotContained() {
        // "/tmp/LumaWall-lib-evil" shares a string prefix with the base but is
        // NOT inside it — the trailing-slash check must reject it.
        let base = URL(fileURLWithPath: "/tmp/LumaWall-lib", isDirectory: true)
        #expect(!PathSafety.contained(
            URL(fileURLWithPath: "/tmp/LumaWall-lib-evil/x.mov"),
            in: base
        ))
    }
}
