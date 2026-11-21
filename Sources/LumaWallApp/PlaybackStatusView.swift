import LumaWallCore
import SwiftUI

/// One display's playback state as a line: an icon, then the state, the copy
/// and rate, and the reason. The icon shape differs by state, so the state
/// doesn't ride on color alone; VoiceOver gets one full sentence.
struct PlaybackStatusLine: View {
    let status: DisplayPlaybackStatus
    let displayName: String

    private var symbol: String {
        switch (status.state, status.reason) {
        case (.paused, _): "pause.circle.fill"
        case (.playing, .some): "leaf.fill"
        case (.playing, .none): "play.circle.fill"
        }
    }

    private var tint: Color {
        switch (status.state, status.reason) {
        case (.paused, _): Theme.textDim
        case (.playing, .some): Theme.warm
        case (.playing, .none): Theme.accent
        }
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            Text(status.summary)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 11, weight: .medium))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(status.accessibilityLabel(displayName: displayName))
    }
}

/// The menu bar popover's per-display state: one row per display that has a
/// wallpaper and a status. Hidden when none does.
struct PlaybackStatusSection: View {
    @Bindable var model: AppModel

    private var rows: [(display: ConnectedDisplay, status: DisplayPlaybackStatus)] {
        model.displays.compactMap { display in
            model.playbackStatus(for: display).map { (display, $0) }
        }
    }

    var body: some View {
        let rows = rows
        // Always present, so opening the popover re-reads even when no row shows yet.
        Group {
            if !rows.isEmpty { list(rows) }
        }
        .onAppear { model.refreshNativePlaybackStatus() }
    }

    private func list(_ rows: [(display: ConnectedDisplay, status: DisplayPlaybackStatus)]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(rows, id: \.display.displayID) { row in
                VStack(alignment: .leading, spacing: 1) {
                    if rows.count > 1 {
                        Text(row.display.name)
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .accessibilityHidden(true)
                    }
                    PlaybackStatusLine(status: row.status, displayName: row.display.name)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
    }
}
