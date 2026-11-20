// Checks on the private WallpaperExtensionKit and CAContext runtime before
// the extension writes into it. The XPC wrapper classes are filled by raw
// writes into their ivars, so each write needs an ivar that exists in the
// live class and has room for the value. An unknown layout fails the
// request that needed it, not the process.

import Foundation
import ObjectiveC

enum RuntimeLayout {
    /// The byte offset of ivar `name` in `cls`, only when `cls` has the
    /// layout the extension was built against (macOS 27.2): a direct
    /// NSObject subclass whose one ivar is `name`, right after the isa, in
    /// an instance one word longer than that, with room for `bytes`. Swift
    /// ivars carry no type encoding, so the field's type can't be read;
    /// accepting only this exact shape rules out inherited, neighbouring and
    /// padded fields. Anything else is an unknown layout.
    static func ivarSlot(named name: String, in cls: AnyClass, bytes: Int) -> Int? {
        let word = MemoryLayout<UnsafeRawPointer>.size
        let base = class_getInstanceSize(NSObject.self)
        guard bytes > 0, bytes <= word, class_getSuperclass(cls) == NSObject.self,
            class_getInstanceSize(cls) == base + word
        else { return nil }
        var count: UInt32 = 0
        guard let ivars = class_copyIvarList(cls, &count) else { return nil }
        defer { free(ivars) }
        guard count == 1, let ivarName = ivar_getName(ivars[0]), String(cString: ivarName) == name,
            ivar_getOffset(ivars[0]) == base
        else { return nil }
        return base
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
