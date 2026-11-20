// Checks on the private WallpaperExtensionKit and CAContext runtime before
// the extension writes into it. The XPC wrapper classes are filled by raw
// writes into their ivars, so each write needs an ivar that exists in the
// live class and has room for the value. An unknown layout fails the
// request that needed it, not the process.

import Foundation
import ObjectiveC

enum RuntimeLayout {
    /// The byte offset of ivar `name` in `cls`, or nil unless it exists,
    /// sits after NSObject's own storage, is aligned for `bytes`, and has
    /// room for `bytes` before the next ivar (or the end of the instance),
    /// so the write can't spill into a neighbouring field. Swift ivars have
    /// no type encoding, so the gap to the next ivar is the field's size.
    static func ivarSlot(named name: String, in cls: AnyClass, bytes: Int) -> Int? {
        guard bytes > 0, let ivar = class_getInstanceVariable(cls, name) else { return nil }
        let offset = ivar_getOffset(ivar)
        guard offset >= class_getInstanceSize(NSObject.self), offset % min(bytes, 8) == 0 else { return nil }
        var count: UInt32 = 0
        guard let ivars = class_copyIvarList(cls, &count) else { return nil }
        defer { free(ivars) }
        let fieldEnd =
            (0..<Int(count)).map { ivar_getOffset(ivars[$0]) }.filter { $0 > offset }.min()
            ?? class_getInstanceSize(cls)
        return fieldEnd - offset >= bytes ? offset : nil
    }

    /// Whether `object` answers every instance method in `names`.
    static func responds(_ object: NSObject, to names: [String]) -> Bool {
        names.allSatisfy { object.responds(to: NSSelectorFromString($0)) }
    }

    /// Whether `cls` answers the class method `name`. Calling one it
    /// doesn't raises an exception that ends the process.
    static func respondsToClassSelector(_ cls: AnyClass, _ name: String) -> Bool {
        (cls as AnyObject).responds(to: NSSelectorFromString(name))
    }
}
