import AppKit
import LumaWallCore
import SwiftUI

// MARK: - Shared UI

struct WallpaperPosterFrame<Overlay: View>: View {
    let posterURL: URL?
    var cornerRadius: CGFloat = 16
    @ViewBuilder var overlay: () -> Overlay

    init(
        posterURL: URL?,
        cornerRadius: CGFloat = 16,
        @ViewBuilder overlay: @escaping () -> Overlay = { EmptyView() }
    ) {
        self.posterURL = posterURL
        self.cornerRadius = cornerRadius
        self.overlay = overlay
    }

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(Theme.panelStrong)
            .aspectRatio(16 / 10, contentMode: .fit)
            .overlay {
                PosterImage(url: posterURL)
            }
            .overlay { overlay() }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

struct TileHoverActions: View {
    let onUse: () -> Void
    let onPreview: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onUse) {
                Label("Use", systemImage: "display")
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 12)
                    .frame(height: 32)
                    .background(Theme.accent, in: Capsule())
                    .foregroundStyle(.black)
            }
            .buttonStyle(.plain)

            Button(action: onPreview) {
                Label("Preview", systemImage: "play.fill")
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 12)
                    .frame(height: 32)
                    .background(.white.opacity(0.12), in: Capsule())
                    .overlay(Capsule().stroke(.white.opacity(0.2)))
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct WallpaperTile: View {
    @Bindable var model: AppModel
    let asset: WallpaperAsset
    var width: CGFloat? = nil
    var showCategory: Bool = false
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            WallpaperPosterFrame(posterURL: asset.posterURL, cornerRadius: 16) {
                ZStack {
                    if hovering {
                        LoopingVideoView(url: asset.mediaURL)
                            .scaledToFill()
                            .transition(.opacity)
                        Color.black.opacity(0.28)
                            .transition(.opacity)
                    }
                }
            }
            .overlay(alignment: .top) {
                HStack {
                    if model.isActive(asset) {
                        Text("LIVE")
                            .font(.system(size: 9, weight: .bold))
                            .padding(.horizontal, 7)
                            .frame(height: 20)
                            .background(Theme.accent.opacity(0.92), in: Capsule())
                            .foregroundStyle(.black)
                    }
                    Spacer()
                    Button { model.toggleFavorite(asset) } label: {
                        Image(systemName: model.isFavorite(asset) ? "heart.fill" : "heart")
                            .foregroundStyle(model.isFavorite(asset) ? .pink : .white)
                            .frame(width: 28, height: 28)
                            .background(.black.opacity(0.45), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(model.isFavorite(asset) ? "Remove favorite" : "Add favorite")
                }
                .padding(10)
            }
            .overlay {
                if hovering {
                    TileHoverActions(
                        onUse: { model.apply(asset) },
                        onPreview: { model.previewAsset = asset }
                    )
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(hovering ? Theme.accent.opacity(0.45) : Theme.line, lineWidth: 1)
            )
            .shadow(color: .black.opacity(hovering ? 0.28 : 0.14), radius: hovering ? 12 : 6, y: hovering ? 6 : 3)
            .animation(.snappy(duration: 0.22), value: hovering)
            .onHover { hovering = $0 }

            VStack(alignment: .leading, spacing: 3) {
                Text(asset.name)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                if showCategory {
                    Text("\(asset.category.title) · \(asset.resolutionLabel) · \(Int(asset.framesPerSecond)) FPS")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textDim)
                } else {
                    Text("\(Int(asset.pixelSize.width))×\(Int(asset.pixelSize.height)) · \(Int(asset.framesPerSecond)) FPS")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textDim)
                }
            }
            .padding(.horizontal, 2)
        }
        .frame(width: width)
        .onTapGesture { model.previewAsset = asset }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(asset.name)
    }
}

struct LibraryCard: View {
    @Bindable var model: AppModel
    let asset: WallpaperAsset
    @State private var draftName: String = ""
    @State private var isEditingName = false
    @FocusState private var nameFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            WallpaperTile(model: model, asset: asset, showCategory: true)

            if isEditingName {
                TextField("Name", text: $draftName)
                    .textFieldStyle(.roundedBorder)
                    .focused($nameFocused)
                    .onSubmit { commitRename() }
                    .onAppear {
                        draftName = asset.name
                        nameFocused = true
                    }
                    .onChange(of: nameFocused) { _, focused in
                        if !focused { commitRename() }
                    }
            } else {
                Text(asset.name)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .padding(.horizontal, 2)
            }

            HStack(spacing: 8) {
                Menu {
                    ForEach(WallpaperCategory.allCases) { category in
                        Button {
                            model.setCategory(category, for: asset)
                        } label: {
                            HStack {
                                Text(category.title)
                                if asset.category == category {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    Label(asset.category.title, systemImage: asset.category.symbol)
                        .font(.system(size: 12, weight: .semibold))
                }
                .menuStyle(.borderlessButton)

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
                    Label("Apply to…", systemImage: "display")
                        .font(.system(size: 12, weight: .semibold))
                }
                .menuStyle(.borderlessButton)

                Spacer()

                Button(role: .destructive) { model.remove(asset) } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 2)
        }
        .contextMenu {
            Button("Rename…") {
                draftName = asset.name
                isEditingName = true
            }
            Button(model.isFavorite(asset) ? "Unlike" : "Like") {
                model.toggleFavorite(asset)
            }
            Divider()
            Button("Remove", role: .destructive) { model.remove(asset) }
        }
    }

    private func commitRename() {
        let trimmed = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        isEditingName = false
        guard !trimmed.isEmpty, trimmed != asset.name else { return }
        model.rename(asset, to: trimmed)
    }
}
