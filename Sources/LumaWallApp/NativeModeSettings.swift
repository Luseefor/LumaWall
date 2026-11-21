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
            setEnabled: { model.setNativeMode(enabled: $0) },
            restore: { model.restoreOriginalWallpaper() }
        )
    }
}

struct NativeModeControls: View {
    let enabled: Bool
    let hostMode: WallpaperHostMode
    let fallbackDisplayCount: Int
    let canRestore: Bool
    let setEnabled: (Bool) -> Void
    let restore: () -> Void
    @State private var confirmsTurningOn = false

    var body: some View {
        VStack(spacing: 0) {
            row(title: AppModel.NativeModeText.title, detail: modeDetail, symbol: "testtube.2") {
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
            if canRestore {
                Divider().overlay(Theme.line)
                row(
                    title: "Restore original wallpaper",
                    detail: enabled
                        ? "Turns native mode off and puts back the wallpaper you had before LumaWall set it."
                        : "Puts back the wallpaper you had before LumaWall set it.",
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

    private func row<Trailing: View>(
        title: String, detail: String, symbol: String, @ViewBuilder trailing: () -> Trailing
    ) -> some View {
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
