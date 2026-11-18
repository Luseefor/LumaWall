import AppKit
import LumaWallCore
import SwiftUI

struct LibrarySelectionTile: View {
    @Bindable var model: AppModel
    let asset: WallpaperAsset
    let isSelected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            VStack(alignment: .leading, spacing: 9) {
                WallpaperPosterFrame(posterURL: asset.posterURL, fallbackVideoURL: asset.mediaURL, cornerRadius: 13) {
                    EmptyView()
                }
                .overlay(alignment: .topLeading) {
                    HStack(spacing: 6) {
                        if model.isActive(asset) {
                            Text("IN USE")
                                .padding(.horizontal, 7)
                                .frame(height: 18)
                                .foregroundStyle(.black)
                                .background(Theme.accent, in: Capsule())
                        }
                        if model.isFavorite(asset) {
                            Image(systemName: "heart.fill")
                                .foregroundStyle(.pink)
                                .frame(width: 22, height: 22)
                                .background(.black.opacity(0.55), in: Circle())
                        }
                    }
                    .font(.system(size: 9, weight: .bold))
                    .padding(9)
                }

                Text(asset.name)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Text("\(asset.resolutionLabel) · \(Int(asset.framesPerSecond)) FPS · \(asset.category.title)")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textDim)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(
                isSelected ? Theme.accent.opacity(0.13) : Theme.panel,
                in: RoundedRectangle(cornerRadius: 17, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 17, style: .continuous)
                    .stroke(isSelected ? Theme.accent : Theme.line, lineWidth: isSelected ? 2 : 1)
            )
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Preview") { model.previewAsset = asset }
            Button("Use on Main Display") { model.apply(asset) }
            Button("Use on All Displays") { model.applyToAll(asset) }
            Button(model.isFavorite(asset) ? "Remove Favorite" : "Add Favorite") {
                model.toggleFavorite(asset)
            }
            Divider()
            Button("Remove from Library", role: .destructive) { model.remove(asset) }
        }
        .accessibilityLabel("\(asset.name), \(asset.resolutionLabel), \(Int(asset.framesPerSecond)) frames per second")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

struct LibraryInspector: View {
    @Bindable var model: AppModel
    let asset: WallpaperAsset?
    @State private var draftName = ""

    var body: some View {
        Group {
            if let asset {
                GeometryReader { viewport in
                    ScrollView(.vertical) {
                        VStack(alignment: .leading, spacing: 16) {
                        poster(asset)
                        TextField("Wallpaper name", text: $draftName)
                            .font(.title3.weight(.semibold))
                            .textFieldStyle(.plain)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .clipped()
                            .onSubmit { commitName(asset) }
                        metadata(asset)
                        Divider().overlay(Theme.line)
                        Picker("Category", selection: Binding(
                            get: { asset.category },
                            set: { model.setCategory($0, for: asset) }
                        )) {
                            ForEach(WallpaperCategory.allCases) { category in
                                Label(category.title, systemImage: category.symbol).tag(category)
                            }
                        }
                        .pickerStyle(.menu)

                        if !model.displaysUsing(asset).isEmpty {
                            VStack(alignment: .leading, spacing: 7) {
                                Text("Currently displayed on")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(Theme.textDim)
                                ForEach(model.displaysUsing(asset)) { display in
                                    Label(display.name, systemImage: "display")
                                        .font(.subheadline)
                                }
                            }
                        }

                        Menu {
                            Button("Main Display") { model.apply(asset) }
                            Button("All Displays") { model.applyToAll(asset) }
                            if model.displays.count > 1 {
                                Button("Span Across Displays") { model.spanAcrossAllDisplays(asset) }
                            }
                            Divider()
                            ForEach(model.displays) { display in
                                Button(display.name) { model.apply(asset, to: display.displayID) }
                            }
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "display")
                                Text("Use as Wallpaper")
                                    .font(.system(size: 13, weight: .semibold))
                                Spacer()
                                Image(systemName: "chevron.down")
                                    .font(.system(size: 11, weight: .bold))
                            }
                            .foregroundStyle(.black)
                            .padding(.horizontal, 14)
                            .frame(maxWidth: .infinity)
                            .frame(height: 40)
                            .background(Theme.accent, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                        }
                        .menuStyle(.borderlessButton)

                        HStack {
                            GhostButton("Preview", symbol: "play.fill") { model.previewAsset = asset }
                            GhostButton(
                                model.isFavorite(asset) ? "Favorited" : "Favorite",
                                symbol: model.isFavorite(asset) ? "heart.fill" : "heart"
                            ) { model.toggleFavorite(asset) }
                        }
                        Button("Remove from Library", role: .destructive) { model.remove(asset) }
                            .buttonStyle(.plain)
                            .foregroundStyle(.red.opacity(0.9))
                        }
                        // Scroll views otherwise let media and long filenames choose
                        // an oversized ideal width, which can push the leading edge
                        // underneath the inspector's rounded border.
                        .frame(width: max(viewport.size.width - 36, 1), alignment: .leading)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 18)
                    }
                    .scrollIndicators(.visible)
                }
                .onAppear { draftName = asset.name }
                .onChange(of: asset.id) { _, _ in draftName = asset.name }
            } else {
                ContentUnavailableView(
                    "Select a Wallpaper",
                    systemImage: "rectangle.stack",
                    description: Text("Its details and display controls will appear here.")
                )
            }
        }
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Theme.line))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func poster(_ asset: WallpaperAsset) -> some View {
        Group {
            PosterImage(url: asset.posterURL, fallbackVideo: asset.mediaURL)
        }
        .frame(maxWidth: .infinity)
        .aspectRatio(16 / 10, contentMode: .fit)
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay(alignment: .bottomLeading) {
            if model.isActive(asset) {
                Text("PLAYING")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 9)
                    .frame(height: 22)
                    .background(Theme.accent, in: Capsule())
                    .padding(10)
            }
        }
    }

    private func metadata(_ asset: WallpaperAsset) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
            inspectorRow("Resolution", "\(Int(asset.pixelSize.width)) × \(Int(asset.pixelSize.height))")
            inspectorRow("Frame rate", "\(Int(asset.framesPerSecond)) FPS")
            inspectorRow("Duration", asset.duration.formatted(.number.precision(.fractionLength(1))) + " sec")
            inspectorRow("Added", asset.createdAt.formatted(date: .abbreviated, time: .omitted))
            inspectorRow("Used", "\(asset.applyCount) time\(asset.applyCount == 1 ? "" : "s")")
            inspectorRow("Audio", asset.containsAudio ? "Present" : "Removed")
        }
        .font(.system(size: 11))
    }

    private func inspectorRow(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(Theme.textDim)
            Text(value).monospacedDigit()
        }
    }

    private func commitName(_ asset: WallpaperAsset) {
        let trimmed = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != asset.name else {
            draftName = asset.name
            return
        }
        model.rename(asset, to: trimmed)
    }
}

struct AutomationSlotCard: View {
    let symbol: String
    let title: String
    let detail: String
    let footnote: String
    let asset: WallpaperAsset?
    var height: CGFloat = 168
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                PosterImage(url: asset?.posterURL)
                LinearGradient(
                    colors: [.black.opacity(0.55), .black.opacity(0.15), .clear],
                    startPoint: .bottom,
                    endPoint: .top
                )
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Image(systemName: symbol)
                        Text(title).font(.system(size: 13, weight: .semibold))
                    }
                    Spacer()
                    if asset == nil {
                        Image(systemName: "plus")
                            .font(.title3.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .foregroundStyle(.white.opacity(0.85))
                    }
                    Spacer()
                    Text(asset?.name ?? detail)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                    Text(footnote)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.65))
                }
                .padding(14)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .foregroundStyle(.white)
            }
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Theme.line)
            )
        }
        .buttonStyle(.plain)
    }
}

struct ShelfRow<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 16) {
                content()
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 1)
        }
    }
}

struct ShelfAddCard: View {
    let title: String
    let caption: String
    let width: CGFloat
    let height: CGFloat
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: "plus")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Text(caption)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textDim)
                    .multilineTextAlignment(.center)
            }
            .padding(14)
            .frame(width: width, height: height)
            .background(Theme.panel.opacity(0.5), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(style: StrokeStyle(lineWidth: 1.2, dash: [7, 5]))
                    .foregroundStyle(Theme.line)
            )
        }
        .buttonStyle(.plain)
    }
}

struct PlaylistShelfCard: View {
    @Bindable var model: AppModel
    let playlist: WallpaperPlaylist
    let width: CGFloat
    let height: CGFloat

    private var isActive: Bool { model.activePlaylistID == playlist.id }

    private var posterURL: URL? {
        for id in playlist.wallpaperIDs {
            if let url = model.asset(for: id)?.posterURL {
                return url
            }
        }
        return nil
    }

    var body: some View {
        Button(action: toggleRotation) {
            ZStack {
                PosterImage(url: posterURL)
                LinearGradient(
                    colors: [.black.opacity(0.78), .black.opacity(0.2), .clear],
                    startPoint: .bottom,
                    endPoint: .top
                )
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Image(systemName: isActive ? "play.fill" : "list.and.film")
                        if isActive {
                            Text("ACTIVE")
                                .font(.system(size: 9, weight: .bold))
                                .padding(.horizontal, 7)
                                .frame(height: 17)
                                .background(Theme.accent.opacity(0.92), in: Capsule())
                                .foregroundStyle(.black)
                        }
                    }
                    Spacer()
                    Text(playlist.name)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Text("\(playlist.wallpaperIDs.count) items · \(playlist.shuffled ? "Shuffled" : "Ordered") · every \(playlist.intervalMinutes)m")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.65))
                        .lineLimit(1)
                }
                .padding(14)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .foregroundStyle(.white)
            }
            .frame(width: width, height: height)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(isActive ? Theme.accent.opacity(0.55) : Theme.line, lineWidth: isActive ? 1.6 : 1)
            )
        }
        .buttonStyle(.plain)
        .help(isActive ? "Stop rotation" : "Start this playlist")
        .accessibilityLabel("\(playlist.name) playlist")
        .contextMenu {
            Button(isActive ? "Stop Rotation" : "Apply Playlist", action: toggleRotation)
            Button("Edit…") { model.beginPlaylistEditor(existing: playlist) }
            Divider()
            Button("Delete", role: .destructive) { model.deletePlaylist(playlist) }
        }
    }

    private func toggleRotation() {
        if isActive {
            model.stopPlaylistRotation()
        } else {
            model.applyPlaylist(playlist)
        }
    }
}

struct LibraryInspectorSheet: View {
    @Bindable var model: AppModel
    let asset: WallpaperAsset
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 14) {
            LibraryInspector(model: model, asset: asset)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack {
                Spacer()
                Button("Done", action: dismiss.callAsFunction)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(18)
        .frame(width: 420, height: 660)
    }
}

struct AutomationPickSheet: View {
    @Bindable var model: AppModel
    let slot: AppModel.AutomationSlot
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                BrandMark(size: 28)
                Text("Choose \(slot.title) wallpaper").font(.title2.bold())
            }
            if model.assets.isEmpty {
                Text("Import a wallpaper first.").foregroundStyle(Theme.textDim)
            } else {
                List(model.assets) { asset in
                    Button {
                        model.assignAutomation(slot: slot, asset: asset)
                        dismiss()
                    } label: {
                        HStack {
                            Text(asset.name)
                            Spacer()
                            if model.asset(for: id(for: slot))?.id == asset.id {
                                Image(systemName: "checkmark").foregroundStyle(Theme.accent)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            HStack {
                if model.asset(for: id(for: slot)) != nil {
                    Button("Clear slot", role: .destructive) {
                        model.clearAutomation(slot: slot)
                        dismiss()
                    }
                }
                Spacer()
                Button("Close", action: dismiss.callAsFunction)
            }
        }
        .padding(20)
        .frame(width: 440, height: 500)
    }

    private func id(for slot: AppModel.AutomationSlot) -> WallpaperID? {
        switch slot {
        case .day: model.automations.dayWallpaperID
        case .night: model.automations.nightWallpaperID
        case .light: model.automations.lightWallpaperID
        case .dark: model.automations.darkWallpaperID
        case .lock: model.automations.lockScreenWallpaperID
        }
    }
}
