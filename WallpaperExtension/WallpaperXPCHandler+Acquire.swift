import AppKit
import AVFoundation
import CoreMedia
import os
import QuartzCore

/// The no-video gradient, under any other sublayer. A CAGradientLayer
/// composites in the agent's CALayerHost, unlike `CALayer.contents`.
func installGradientFallback(on rootLayer: CALayer) {
    let gradientLayer = CAGradientLayer()
    gradientLayer.colors = [
        CGColor(red: 0.2, green: 0.0, blue: 0.5, alpha: 1.0),
        CGColor(red: 0.0, green: 0.3, blue: 0.7, alpha: 1.0),
        CGColor(red: 0.0, green: 0.6, blue: 0.4, alpha: 1.0),
    ]
    gradientLayer.startPoint = CGPoint(x: 0, y: 0)
    gradientLayer.endPoint = CGPoint(x: 1, y: 1)
    gradientLayer.frame = rootLayer.bounds
    gradientLayer.contentsScale = rootLayer.contentsScale
    CATransaction.begin(); CATransaction.setDisableActions(true)
    rootLayer.insertSublayer(gradientLayer, at: 0)
    CATransaction.commit(); CATransaction.flush()
}

/// Keep the fallback gradient covering its root after a resize, which
/// re-frames the root by hand. Inside the caller's transaction.
func reframeGradientFallback(on rootLayer: CALayer) {
    rootLayer.sublayers?.filter { $0 is CAGradientLayer }.forEach { $0.frame = rootLayer.bounds }
}

/// Reply to a deferred acquire with `contextId`, or fail it when teardown
/// removed that context first. The closure runs on `Lifecycle.queue`, where teardown
/// runs, so the check and the reply can't straddle one.
func heldReply<Reply>(
    _ boxedReply: SendableBox<Reply>, contextId: UInt32, key: DisplayKey,
    reply: @escaping @Sendable (Any?, (any Error)?) -> Void,
) -> @Sendable () -> Void {
    {
        guard WallpaperState.shared.context(for: key)?.contextId == contextId else {
            extensionLog("  [acquire] context \(contextId) was torn down before its reply, failing the acquire")
            reply(
                nil,
                NSError(
                    domain: "LumaWallExtension", code: 5,
                    userInfo: [NSLocalizedDescriptionKey: "Surface was torn down before the acquire replied"]))
            return
        }
        reply(boxedReply.value, nil)
    }
}

/// `token`'s create has put something displayable in `key`'s layer, or
/// given up: send its reply and those of acquires that reused the surface
/// meanwhile. A create whose context was torn down sends nothing; teardown
/// answered its replies.
func surfaceReady(_ key: DisplayKey, token: Int) {
    Lifecycle.queue.async { Lifecycle.replies.ready(key, token: token).forEach { $0() } }
}

extension WallpaperXPCHandler {
    func acquire(withId id: Any?, request: Any?, reply: @escaping @Sendable (Any?, (any Error)?) -> Void) {
        markServed()
        nonisolated(unsafe) let unsafeRequest = request
        nonisolated(unsafe) let unsafeID = id
        nonisolated(unsafe) let handler = self
        Lifecycle.queue.async { handler.acquireBody(id: unsafeID, request: unsafeRequest, reply: reply) }
    }

    private func acquireBody(id: Any?, request: Any?, reply: @escaping @Sendable (Any?, (any Error)?) -> Void) {
        traceLog("=== ACQUIRE ===")
        LumaWallExtension.catchUpDisplaySleep()

        // Extract destination size from WallpaperCreationRequestXPC
        var destSize = CGSize(width: 2_560, height: 1_440)  // fallback
        var scaleFactor: CGFloat = 2.0
        var isPreview = false
        var displayID: UInt32?
        var didExtractGeometry = false
        if let reqObj = request as? NSObject {
            let mirror = Mirror(reflecting: reqObj)
            for child in mirror.children {
                let reqMirror = Mirror(reflecting: child.value)
                for prop in reqMirror.children {
                    if prop.label == "destination" {
                        let destMirror = Mirror(reflecting: prop.value)
                        for destProp in destMirror.children {
                            if destProp.label == "size", let size = destProp.value as? CGSize {
                                destSize = size
                                didExtractGeometry = true
                            } else if destProp.label == "scaleFactor", let sf = destProp.value as? CGFloat {
                                scaleFactor = sf
                            } else if destProp.label == "directDisplayID", let did = destProp.value as? UInt32 {
                                displayID = did
                            }
                        }
                    } else if prop.label == "isPreview", let preview = prop.value as? Bool {
                        isPreview = preview
                    } else if prop.label == "cacheDirectory" {
                        if let url = prop.value as? URL {
                            WallpaperState.shared.cacheDirectoryURL = url
                        }
                    }
                }
            }
        }
        // Mirror layout is private and can shift between OS versions. If it failed,
        // fall back to the live display's pixel size instead of a hardcoded 1440p.
        // A wrong-sized root layer renders into a sub-region (half off-screen).
        if !didExtractGeometry, let did = displayID, CGDisplayPixelsWide(did) > 0 {
            let w = CGFloat(CGDisplayPixelsWide(did))
            let h = CGFloat(CGDisplayPixelsHigh(did))
            // destSize is in points; derive it from pixels / scale when possible.
            if w > 0, h > 0 {
                destSize = CGSize(width: w / max(scaleFactor, 1), height: h / max(scaleFactor, 1))
                extensionLog("  [acquire] geometry Mirror missed, fell back to live display \(did): \(destSize) @\(scaleFactor)x")
            }
        }
        // Ground-truth guard: a non-preview surface must cover its display. A
        // stale probe or thumbnail-size acquire reusing a desktop key would
        // otherwise mint a stuck half-scale surface (e.g. 1280x720 on a 1440p
        // display): the agent hosts it small over the full-bleed still, and
        // nothing ever heals it because later same-size re-acquires read as
        // "unchanged". Clamp clear outliers to the live display geometry.
        // Previews keep their small sizes. This also heals already-shrunken
        // surfaces: the next same-role full-size re-acquire now differs from
        // the stored size, so the REUSE path re-frames to full.
        (destSize, scaleFactor) = Self.validatedGeometry(
            destSize: destSize, scaleFactor: scaleFactor,
            displayID: displayID, isPreview: isPreview
        )
        // A size that isn't a plausible pixel count fails this request
        // before anything is registered for it.
        guard let pixels = StillSize(points: destSize, scale: scaleFactor) else {
            extensionLog("  [acquire] rejected geometry \(destSize) @\(scaleFactor)x")
            reply(
                nil,
                NSError(
                    domain: "LumaWallExtension", code: 6,
                    userInfo: [NSLocalizedDescriptionKey: "Acquire geometry out of range"]))
            return
        }
        // Extract choice configuration and files from descriptor via Mirror traversal
        // Path: WallpaperCreationRequestXPC.rawValue.descriptor.{configuration, files}
        var choiceConfiguration: String?
        var choiceFiles: [URL] = []
        if let reqObj = request as? NSObject {
            let mirror = Mirror(reflecting: reqObj)
            if let rawValue = mirror.children.first?.value {
                let rawMirror = Mirror(reflecting: rawValue)
                for prop in rawMirror.children where prop.label == "descriptor" {
                    let descMirror = Mirror(reflecting: prop.value)
                    for descProp in descMirror.children {
                        if descProp.label == "configuration" {
                            if let data = descProp.value as? Data, !data.isEmpty {
                                choiceConfiguration = String(data: data, encoding: .utf8)
                            }
                        } else if descProp.label == "files" {
                            if let urls = descProp.value as? [URL] {
                                choiceFiles = urls
                            }
                        }
                    }
                }
            }
            // If direct Mirror didn't work, try string description parsing as fallback
            if choiceConfiguration == nil {
                let desc = String(describing: reqObj)
                // Look for our identifier in the description
                if let idRange = desc.range(of: "identifier: \"") {
                    let after = desc[idRange.upperBound...]
                    if let endQuote = after.firstIndex(of: "\"") {
                        let identifier = String(after[..<endQuote])
                        traceLog("  [Choice] Fallback extraction from description: identifier=\(identifier)")
                        choiceConfiguration = identifier
                    }
                }
            }
        }

        traceLog(
            "  destination: \(destSize) @\(scaleFactor)x, isPreview: \(isPreview), pid: \(connectionPID), choice: \(choiceConfiguration ?? "nil"), files: \(choiceFiles.map(LogRedaction.fileLabel))"
        )

        // Native shuffle: adopt the frequency the host sent (optionValues in the
        // descriptor; absent until the user touches the picker), then resolve the
        // sentinel to the concrete video this surface should render. Contexts keep
        // the RAW choice so re-acquires and switch decisions compare correctly.
        let shuffleFrequency = extractPickerOptionValue("shuffleFrequency", fromRequest: request)
        ShuffleController.shared.noteAcquire(choice: choiceConfiguration, frequencyID: shuffleFrequency)
        AutomationController.shared.noteAcquire(choice: choiceConfiguration)
        let renderChoice = AutomationController.shared.resolveChoice(
            ShuffleController.shared.resolveChoice(choiceConfiguration)
        )
        acquiredAsPreview = isPreview

        // Each acquire's `choiceConfiguration` is authoritative for *this* display's
        // context. Do NOT mutate the process-wide `currentVideoID` here based on a
        // diff. Concurrent acquires for different displays would race and a renderer
        // can end up initialized with the wrong monitor's video. The global tracks
        // the last user-picked choice (via `selectedChoicesDidChange`); we only seed
        // it on first launch when UserDefaults has no value yet, so the menu-bar UI
        // has something sensible to show before the user picks anything.
        if WallpaperState.shared.currentVideoID == nil, let videoID = renderChoice {
            WallpaperState.shared.currentVideoID = videoID
        }

        // Each WallpaperID (a Space, the lock-screen surface, or a Settings preview) is its own
        // hosted surface and must get its OWN CAContext. Sharing one context per display let a
        // second Space or the lock surface steal it and black out the first. Key the context by
        // the WallpaperID UUID; fall back to a per-display constant if an id ever lacks one.
        let displayID0 = displayID ?? 0
        let surfaceUUID = extractWallpaperUUID(fromID: id) ?? Self.fallbackSurfaceUUID(forDisplay: displayID0)
        let key = DisplayKey(displayID: displayID0, surfaceUUID: surfaceUUID)
        WallpaperState.shared.registerWallpaperID(surfaceUUID, key: key)
        // A re-acquire of THIS surface (display woke / preview refresh / switch) cancels its
        // pending teardown so a brief invalidate→re-acquire flicker doesn't drop it,
        // and resumes the playback the invalidate stopped.
        cancelTeardown(for: key)
        if WallpaperState.shared.noteAcquire(for: key, byPreview: isPreview, connection: connectionSerial) == true {
            extensionLog("  [acquire] reopened surface on display \(key.displayID), playback resumes in place")
        }
        let videoURL = findVideoURL(forChoice: renderChoice)
        // Read (and later decode) the cached still only where a new renderer
        // is seeded with it: a same-choice re-acquire or an in-place switch
        // never uses it.
        let pixelWidth = pixels.width, pixelHeight = pixels.height
        let loadStill = { @Sendable [choiceConfiguration] (url: URL) in
            loadCachedSnapshotImage(forChoice: choiceConfiguration, videoURL: url, pixelWidth: pixelWidth, pixelHeight: pixelHeight)
        }

        // Diagnostic bisection: host a still only (no video pipeline). Same context
        // reuse/create/reply as below. That's what we're stress-testing, but there is no renderer.
        if Bisect.stillOnly {
            acquireStillOnlyBisect(
                key: key, displayID: displayID, destSize: destSize, scaleFactor: scaleFactor, videoURL: videoURL,
                cachedStill: videoURL.flatMap(loadStill), choice: choiceConfiguration, reply: reply)
            return
        }

        let acquired = AcquiredRequest(
            key: key, displayID: displayID, displayID0: displayID0, destSize: destSize, scaleFactor: scaleFactor,
            isPreview: isPreview, choiceConfiguration: choiceConfiguration, renderChoice: renderChoice,
            videoURL: videoURL, pixelWidth: pixelWidth, pixelHeight: pixelHeight, loadStill: loadStill,
        )

        // ---- REUSE: the display's single persistent context already exists ----
        // Return the SAME contextId regardless of whether this is the desktop or a
        // Settings-preview acquire, both host one surface (no gray gap, no
        // accumulation, no orphan). Only swap the video if the choice actually
        // changed; re-selecting the same wallpaper is a no-op.
        if let existing = WallpaperState.shared.context(for: key) {
            acquireReuse(existing, acquired, reply: reply)
            return
        }

        // ---- CREATE: first acquire for this display slot ----
        acquireCreate(acquired, reply: reply)
    }
}

/// What `acquireBody` read from an acquire request, for its reuse and
/// create halves.
struct AcquiredRequest {
    let key: DisplayKey
    let displayID: UInt32?
    let displayID0: UInt32
    let destSize: CGSize
    let scaleFactor: CGFloat
    let isPreview: Bool
    let choiceConfiguration: String?
    let renderChoice: String?
    let videoURL: URL?
    let pixelWidth: Int
    let pixelHeight: Int
    let loadStill: @Sendable (URL) -> CGImage?
}
