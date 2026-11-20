import Foundation
import IOSurface
import QuartzCore

/// A remote CAContext for `displayID` (or the default display), or nil when
/// it can't be made. The class methods are private API, so each is checked
/// before the call: sending one CAContext doesn't answer would raise and end
/// the process.
func makeRemoteCAContext(displayID: UInt32?) -> CAContext? {
    let raw: Any?
    if let displayID {
        guard RuntimeLayout.respondsToClassSelector(CAContext.self, "remoteContextWithOptions:") else {
            extensionLog("  ERROR: CAContext has no remoteContextWithOptions:")
            return nil
        }
        raw = CAContext.perform(NSSelectorFromString("remoteContextWithOptions:"), with: ["displayId": displayID])?
            .takeUnretainedValue()
    } else {
        guard RuntimeLayout.respondsToClassSelector(CAContext.self, "remoteContext") else {
            extensionLog("  ERROR: CAContext has no remoteContext")
            return nil
        }
        raw = CAContext.remoteContext()
    }
    guard let context = raw as? CAContext, context.contextId != 0 else { return nil }
    return context
}

/// Construct a WallpaperRemoteContextXPC wrapping the given CAContext ID.
/// The real class has a `box` ivar holding a WallpaperExtensionRemoteContext,
/// whose first field is the UInt32 remoteContextID (offset 8 in a 16-byte
/// instance on macOS 27.2). Nil when the live class has no such ivar.
func createRemoteContextXPC(contextId: UInt32) -> AnyObject? {
    guard let realClass = objc_getClass("WallpaperRemoteContextXPC") as? AnyClass else {
        extensionLog("  ERROR: WallpaperRemoteContextXPC class missing")
        return nil
    }
    guard let offset = RuntimeLayout.ivarSlot(named: "box", in: realClass, bytes: MemoryLayout<UInt32>.size) else {
        extensionLog("  ERROR: WallpaperRemoteContextXPC layout unexpected (no box ivar that fits a UInt32)")
        return nil
    }
    guard let raw = class_createInstance(realClass, 0) else {
        extensionLog("  ERROR: Could not create WallpaperRemoteContextXPC")
        return nil
    }
    let obj = raw as AnyObject
    Unmanaged.passUnretained(obj).toOpaque().advanced(by: offset).storeBytes(of: contextId, as: UInt32.self)
    traceLog("  Created WallpaperRemoteContextXPC (contextId: \(contextId), offset: \(offset))")
    return obj
}

/// Construct a WallpaperSnapshotXPC wrapping the given IOSurface. The real
/// class has a `rawValue` ivar holding a WallpaperSnapshot, a single
/// retained IOSurface pointer (offset 8 in a 16-byte instance on macOS
/// 27.2). Nil when the live class has no such ivar.
func createSnapshotXPC(surface: IOSurface) -> AnyObject? {
    guard let snapshotXPCClass = objc_getClass("WallpaperSnapshotXPC") as? AnyClass else {
        extensionLog("  [Snapshot] WallpaperSnapshotXPC class missing")
        return nil
    }
    guard
        let offset = RuntimeLayout.ivarSlot(
            named: "rawValue", in: snapshotXPCClass, bytes: MemoryLayout<UnsafeRawPointer>.size)
    else {
        extensionLog("  [Snapshot] WallpaperSnapshotXPC layout unexpected (no rawValue ivar that fits a pointer)")
        return nil
    }
    guard let instance = class_createInstance(snapshotXPCClass, 0) else {
        extensionLog("  [Snapshot] Failed to create WallpaperSnapshotXPC")
        return nil
    }
    let surfaceRef = Unmanaged.passRetained(surface).toOpaque()
    let instancePtr = Unmanaged.passUnretained(instance as AnyObject).toOpaque()
    instancePtr.advanced(by: offset).storeBytes(of: surfaceRef, as: UnsafeRawPointer.self)
    return instance as AnyObject
}
