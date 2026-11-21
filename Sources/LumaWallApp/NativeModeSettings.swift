import SwiftUI

/// The native wallpaper mode switch, its warning, and restoring the user's
/// original wallpaper. Sits in the Settings page's wallpaper host group.
struct NativeModeSettings: View {
    @Bindable var model: AppModel

    var body: some View {
        NativeModeControls(
            enabled: model.nativeModeEnabled,
            hostMode: model.wallpaperHostMode,
            fallbackDisplayCount: model.nativeFallbackDisplayCount,
            canRestore: model.canRestoreOriginalWallpaper,
            layout: model.nativeSurfaceLayout,
            setEnabled: { model.setNativeMode(enabled: $0) },
            setLayout: { model.setNativeSurfaceLayout($0) },
            restore: { model.restoreOriginalWallpaper() }
        )
    }
}

struct NativeModeControls: View {
    let enabled: Bool
    let hostMode: WallpaperHostMode
    let fallbackDisplayCount: Int
    let canRestore: Bool
    let layout: NativeSurfaceLayout
    let setEnabled: (Bool) -> Void
    let setLayout: (NativeSurfaceLayout) -> Void
    let restore: () -> Void
    @State private var confirmsTurningOn = false

    var body: some View {
        VStack(spacing: 0) {
            NativeSettingRow(title: AppModel.NativeModeText.title, detail: modeDetail, symbol: "testtube.2") {
                Toggle(
                    AppModel.NativeModeText.title,
                    isOn: Binding(
                        get: { enabled },
                        set: { on in
                            if on { confirmsTurningOn = true } else { setEnabled(false) }
                        }
                    )
                )
                .labelsHidden()
                .accessibilityLabel(AppModel.NativeModeText.title)
            }
            if enabled, hostMode == .native {
                Divider().overlay(Theme.line)
                NativeLayoutRows(layout: layout, setLayout: setLayout)
            }
            if canRestore {
                Divider().overlay(Theme.line)
                NativeSettingRow(
                    title: "Restore original wallpaper",
                    detail: enabled
                        ? "Turns native mode off, stops LumaWall's wallpapers and puts back the one you had before."
                        : "Stops LumaWall's wallpapers and puts back the one you had before LumaWall set it.",
                    symbol: "arrow.uturn.backward"
                ) {
                    GhostButton("Restore", symbol: "arrow.uturn.backward", action: restore)
                }
            }
        }
        .alert("Turn on native wallpaper mode?", isPresented: $confirmsTurningOn) {
            Button("Turn On") { setEnabled(true) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(AppModel.NativeModeText.warning)
        }
    }

    private var modeDetail: String {
        guard enabled else { return "Off. Wallpapers play in a desktop overlay." }
        guard hostMode == .native else {
            return "Not available on this Mac, so wallpapers play in the overlay."
        }
        switch fallbackDisplayCount {
        case 0: return "On. Wallpapers play through the macOS wallpaper system."
        case 1: return "On. One display uses Safe mode after native mode failed there."
        case let count: return "On. \(count) displays use Safe mode after native mode failed there."
        }
    }
}

/// Where native mode plays the video: everywhere, or the lock screen only
/// with the desktop on the user's picture or a still of the video.
struct NativeLayoutRows: View {
    let layout: NativeSurfaceLayout
    let setLayout: (NativeSurfaceLayout) -> Void

    var body: some View {
        VStack(spacing: 0) {
            NativeSettingRow(
                title: "Play the video on",
                detail: layout.preset == .everywhere
                    ? "The desktop. Lock screens keep their own wallpaper unless you pick one in Library."
                    : "The lock screen. After you unlock, the desktop stays still.",
                symbol: "lock.display"
            ) {
                Picker(
                    "Play the video on",
                    selection: Binding(
                        get: { layout.preset },
                        set: { setLayout(NativeSurfaceLayout(preset: $0, settlesOnStill: layout.settlesOnStill)) }
                    )
                ) {
                    Text("Desktop").tag(NativeSurfaceLayout.Preset.everywhere)
                    Text("Lock screen only").tag(NativeSurfaceLayout.Preset.lockScreenOnly)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .fixedSize()
            }
            if layout.preset == .lockScreenOnly {
                Divider().overlay(Theme.line)
                NativeSettingRow(
                    title: "Desktop after unlock",
                    detail: layout.settlesOnStill
                        ? "Each display shows the first frame of its own video."
                        : "Each display keeps the picture you chose in System Settings.",
                    symbol: "photo"
                ) {
                    Picker(
                        "Desktop after unlock",
                        selection: Binding(
                            get: { layout.settlesOnStill },
                            set: { setLayout(NativeSurfaceLayout(preset: layout.preset, settlesOnStill: $0)) }
                        )
                    ) {
                        Text("Your picture").tag(false)
                        Text("Still of the video").tag(true)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .fixedSize()
                }
            }
        }
    }
}

/// The one-time warning for someone who already used native mode before it
/// became an opt-in.
struct NativeModeDisclosure: ViewModifier {
    @Bindable var model: AppModel

    func body(content: Content) -> some View {
        content.alert(
            "Native wallpaper mode is experimental",
            isPresented: Binding(
                get: { model.needsNativeModeDisclosure },
                set: { _ in }
            )
        ) {
            Button("Keep Native Mode") { model.answerNativeModeDisclosure(keepNativeMode: true) }
            Button("Use Overlay") { model.answerNativeModeDisclosure(keepNativeMode: false) }
        } message: {
            Text(AppModel.NativeModeText.warning + " You can change this in Settings.")
        }
    }
}

/// One row of the native-mode group: icon, title, detail and a control.
struct NativeSettingRow<Trailing: View>: View {
    let title: String
    let detail: String
    let symbol: String
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .frame(width: 28, height: 28)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).fontWeight(.semibold)
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            trailing()
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
        .accessibilityHint(detail)
    }
}
