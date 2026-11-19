import AppKit
import AVFoundation
import CoreMedia
import os
import QuartzCore

extension WallpaperXPCHandler {
    func update(withId _: Any?, request: Any?, reply: @escaping @Sendable ((any Error)?) -> Void) {
        markServed()
        nonisolated(unsafe) let unsafeRequest = request
        nonisolated(unsafe) let handler = self
        Lifecycle.queue.async { handler.updateBody(request: unsafeRequest, reply: reply) }
    }

    private func updateBody(request: Any?, reply: @escaping @Sendable ((any Error)?) -> Void) {
        // Option edits can travel on the update path; adopt a shuffle-frequency
        // change without waiting for the next acquire.
        if let frequency = extractPickerOptionValue("shuffleFrequency", fromRequest: request) {
            ShuffleController.shared.noteFrequencyChange(frequency)
        }

        // Extract presentation mode / activity state by walking the request's Mirror
        // for the named properties and reading the enum case, rather than scanning a
        // stringified description (which silently fell through to "?", and so failed
        // to pause, whenever the description format didn't match). Default to the
        // benign desktop-active values if a field genuinely can't be found.
        var presentationMode = "default"
        var activityState = "active"
        if let request {
            if let mode = mirrorFindProperty("presentationMode", in: request) {
                presentationMode = enumCaseName(mode)
            }
            if let activity = mirrorFindProperty("activityState", in: request) {
                activityState = enumCaseName(activity)
            }
        }

        // Store current mode/state so other policy paths use the correct values.
        WallpaperState.shared.presentationMode = presentationMode
        WallpaperState.shared.activityState = activityState

        // Agent is the authoritative source for presentation mode.
        // Clear the screen-lock override when the Agent confirms the screen isn't locked.
        WallpaperState.shared.isScreenLocked = (presentationMode == "locked")

        let prefs = WallpaperPrefs.shared

        // Apple-like ramp when alwaysPauseDesktop is on:
        // desktop → lock = ramp up (start playing), lock → desktop = ramp down (pause).
        // Only ramp when activity is active (suspended = hard pause, process may sleep).
        let modeChanged = presentationMode != previousPresentationMode
        let animated = prefs.alwaysPauseDesktop
            && activityState == "active"
            && modeChanged

        // A lock or unlock picks the copy and the ramp length from this
        // reading: take a new one rather than trust one from before an unplug.
        // Only the power source; brightness and logging follow off this path.
        let power = modeChanged ? PowerMonitor.shared.readPowerSource() : PowerMonitor.shared.currentState
        prefs.applyPolicies(
            presentationMode: presentationMode,
            activityState: activityState,
            powerState: power,
            animated: animated,
        )

        previousPresentationMode = presentationMode
        reply(nil)
        extensionLog("=== UPDATE (desktop pid \(connectionPID)) === mode: \(presentationMode), activity: \(activityState)")
    }
}

/// Extract the selected id of a picker option (e.g. "shuffleFrequency") from an XPC
/// request whose descriptor carries `optionValues`, a
/// `WallpaperChoiceOptionValues(values: [String: Kind])` map where a picker's value
/// is `Kind.picker(PickerValue(id:))`. The key is absent until the user touches the
/// picker; callers treat nil as "keep the declared default".
func extractPickerOptionValue(_ optionID: String, fromRequest request: Any?) -> String? {
    guard let request,
          let optionValues = mirrorFindProperty("optionValues", in: request),
          let values = mirrorFindProperty("values", in: optionValues)
    else { return nil }
    for entry in Mirror(reflecting: values).children {
        var key: String?
        var kind: Any?
        for pair in Mirror(reflecting: entry.value).children {
            if pair.label == "key" { key = pair.value as? String }
            if pair.label == "value" { kind = pair.value }
        }
        guard key == optionID, let kind else { continue }
        let kindMirror = Mirror(reflecting: kind)
        guard kindMirror.displayStyle == .enum,
              let payload = kindMirror.children.first, payload.label == "picker"
        else { return nil }
        return mirrorFindProperty("id", in: payload.value) as? String
    }
    return nil
}

/// Recursively search a value's `Mirror` for a stored property with the given
/// label, to a shallow depth. Robust to the XPC wrapper nesting, unlike scanning
/// a stringified description.
private func mirrorFindProperty(_ label: String, in value: Any, depth: Int = 0) -> Any? {
    guard depth < 6 else { return nil }
    for child in Mirror(reflecting: value).children {
        if child.label == label { return child.value }
        if let found = mirrorFindProperty(label, in: child.value, depth: depth + 1) { return found }
    }
    return nil
}

/// Extract an enum case name from a value: `.idle` → `"idle"`,
/// `.suspended(reason)` → `"suspended"`. Falls back to `String(describing:)` for
/// non-enums or payload-less cases (whose description is already the case name).
private func enumCaseName(_ value: Any) -> String {
    let mirror = Mirror(reflecting: value)
    if mirror.displayStyle == .enum, let label = mirror.children.first?.label {
        return label
    }
    return String(describing: value)
}
