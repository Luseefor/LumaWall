import AppKit
import LumaWallCore
import SwiftUI

// MARK: - Displays / Playlists / Settings

struct DisplaysPage: View {
    @Bindable var model: AppModel
    private var bounds: CGRect {
        model.displays.map(\.frame).reduce(.null) { $0.union($1) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text(L10n.displays)
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                    .accessibilityAddTraits(.isHeader)
                topology
                    .frame(height: 260)
                    .padding(20)
                    .background(Theme.panel, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 22).stroke(Theme.line))
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 340), spacing: 16)], spacing: 16) {
                    ForEach(model.displays) { DisplayCard(model: model, display: $0) }
                }
            }
            .padding(28)
        }
        .onAppear { model.refreshDisplays() }
    }

    private var topology: some View {
        GeometryReader { geo in
            let world = bounds.isNull ? CGRect(x: 0, y: 0, width: 1, height: 1) : bounds
            let scale = min(geo.size.width / max(world.width, 1), geo.size.height / max(world.height, 1)) * 0.78
            let offsetX = (geo.size.width - world.width * scale) / 2 - world.minX * scale
            let offsetY = (geo.size.height - world.height * scale) / 2 - world.minY * scale
            ZStack(alignment: .topLeading) {
                ForEach(model.displays) { display in
                    let rect = CGRect(
                        x: display.frame.minX * scale + offsetX,
                        y: (world.maxY - display.frame.maxY) * scale + offsetY,
                        width: max(display.frame.width * scale, 160),
                        height: max(display.frame.height * scale, 90)
                    )
                    DisplayMapTile(model: model, display: display)
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                }
            }
        }
    }
}

struct DisplayMapTile: View {
    @Bindable var model: AppModel
    let display: ConnectedDisplay

    var body: some View {
        let asset = model.asset(for: model.activeByDisplay[display.displayID])
        Button {
            model.assignTarget = display
        } label: {
            Color.clear
                .overlay {
                    Group {
                        PosterImage(url: asset?.posterURL)
                    }
                }
                .clipped()
                .overlay(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(display.name)
                            .font(.system(size: 12, weight: .semibold))
                            .lineLimit(1)
                        Text(asset?.name ?? "No wallpaper")
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.75))
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(LinearGradient(colors: [.black.opacity(0.78), .clear], startPoint: .bottom, endPoint: .top))
                }
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(asset == nil ? Theme.line : Theme.accent, lineWidth: asset == nil ? 1 : 2)
                )
        }
        .buttonStyle(.plain)
    }
}

struct DisplayCard: View {
    @Bindable var model: AppModel
    let display: ConnectedDisplay

    var body: some View {
        let asset = model.asset(for: model.activeByDisplay[display.displayID])
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Group {
                    PosterImage(url: asset?.posterURL)
                }
                .frame(width: 72, height: 46)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(display.name).font(.headline).lineLimit(1)
                        if display.isMain {
                            Text("Main")
                                .font(.system(size: 10, weight: .semibold))
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(.white.opacity(0.08), in: Capsule())
                        }
                    }
                    Text("\(Int(display.pixelSize.width))×\(Int(display.pixelSize.height)) · \(Int(display.refreshRate)) Hz")
                        .font(.caption)
                        .foregroundStyle(Theme.textDim)
                    Text(asset?.name ?? "No wallpaper assigned")
                        .font(.subheadline)
                        .foregroundStyle(asset == nil ? Theme.textDim : .primary)
                        .lineLimit(1)
                    if let status = model.playbackStatus(for: display) {
                        PlaybackStatusLine(status: status, displayName: display.name)
                            .padding(.top, 2)
                    }
                }
                Spacer(minLength: 0)
            }
            HStack {
                PrimaryButton("Choose…", symbol: nil) { model.assignTarget = display }
                if asset != nil {
                    GhostButton(
                        model.pausedDisplayIDs.contains(display.displayID) ? "Resume" : "Pause",
                        symbol: nil
                    ) { model.togglePause(on: display) }
                    GhostButton("Clear", symbol: nil) { model.clearDisplay(display) }
                }
            }
        }
        .padding(18)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(Theme.line))
        .onAppear { model.refreshNativePlaybackStatus() }
    }
}
