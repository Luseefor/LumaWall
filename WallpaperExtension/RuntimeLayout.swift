// Checks on the private WallpaperExtensionKit and CAContext runtime before
// the extension writes into it. The XPC wrapper classes are filled by raw
// writes into their ivars, so each write needs an ivar that exists in the
// live class and has room for the value. An unknown layout fails the
// request that needed it, not the process.

import Foundation
import ObjectiveC

enum RuntimeLayout {
    /// The byte offset of ivar `name` in `cls`, or nil unless it exists,
    /// sits after NSObject's own storage, and holds `bytes` within the
    /// instance.
    static func ivarSlot(named name: String, in cls: AnyClass, bytes: Int) -> Int? {
        guard let ivar = class_getInstanceVariable(cls, name) else { return nil }
        let offset = ivar_getOffset(ivar)
        guard offset >= class_getInstanceSize(NSObject.self), bytes > 0,
            offset <= class_getInstanceSize(cls) - bytes
        else { return nil }
        return offset
    }

    /// Whether `cls` answers the class method `name`. Calling one it
    /// doesn't raises an exception that ends the process.
    static func respondsToClassSelector(_ cls: AnyClass, _ name: String) -> Bool {
        (cls as AnyObject).responds(to: NSSelectorFromString(name))
    }
}
