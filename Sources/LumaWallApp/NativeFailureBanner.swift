import SwiftUI

/// Says which displays native mode failed on and that they moved to Safe
/// mode, with Restore Original Wallpaper. In the main window and, compact,
/// in the menu bar popover.
struct NativeFailureBanner: View {
    let notice: NativeFailureNotice
    var compact = false
    let restore: () -> Void
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: compact ? 8 : 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: compact ? 12 : 15, weight: .semibold))
                .foregroundStyle(Theme.warm)
                .padding(.top, 1)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: compact ? 6 : 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(notice.title)
                        .font(.system(size: compact ? 12 : 13, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(notice.message)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textDim)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 8) {
                    Button("Restore Original Wallpaper", action: restore)
                        .buttonStyle(.borderedProminent)
                    Button("Dismiss", action: dismiss)
                        .buttonStyle(.bordered)
                }
                .controlSize(compact ? .small : .regular)
            }
            Spacer(minLength: 0)
        }
        .padding(compact ? 10 : 14)
        .background(Theme.warm.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Theme.warm.opacity(0.35)))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(notice.title)
    }
}
