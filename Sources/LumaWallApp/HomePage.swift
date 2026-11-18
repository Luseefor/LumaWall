import AppKit
import LumaWallCore
import SwiftUI

// MARK: - Home

struct HomePage: View {
    @Bindable var model: AppModel
    @State private var selectedCategory: WallpaperCategory?

    private var recentlyAddedAssets: [WallpaperAsset] {
        let assets = selectedCategory.map(model.assets(in:)) ?? model.assets
        return Array(assets.prefix(12))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                FeaturedHero(model: model)

                if model.assets.isEmpty {
                    EmptyInvite(action: model.chooseVideos)
                        .padding(.horizontal, 28)
                } else {
                    categorySelector

                    horizontalRow(
                        title: "Recently Added",
                        subtitle: selectedCategory.map { "Newest wallpapers in \($0.title)" }
                            ?? "Newest wallpapers in your library",
                        assets: recentlyAddedAssets,
                        seeAll: {
                            model.categoryFilter = selectedCategory
                            model.section = .library
                        }
                    )
                }

                HStack(spacing: 12) {
                    QuickLink(symbol: "display.2", title: "Displays", detail: model.displays.isEmpty ? "Detect screens" : "\(model.displays.count) connected") {
                        model.section = .displays
                    }
                    QuickLink(symbol: "rectangle.stack.fill", title: "Library", detail: model.playlists.isEmpty ? "Playlists & schedules" : "\(model.playlists.count) playlists") {
                        model.section = .library
                    }
                    QuickLink(symbol: "leaf.fill", title: "Energy", detail: model.powerProfile.label) {
                        model.section = .settings
                    }
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 30)
            }
            .padding(.top, 0)
        }
    }

    private var categorySelector: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 9) {
                FilterChip(title: "All", selected: selectedCategory == nil) {
                    selectedCategory = nil
                }
                ForEach(WallpaperCategory.allCases) { category in
                    FilterChip(title: category.title, selected: selectedCategory == category) {
                        selectedCategory = category
                    }
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 2)
        }
        .accessibilityLabel("Wallpaper categories")
    }

    @ViewBuilder
    private func horizontalRow(
        title: String,
        subtitle: String,
        assets: [WallpaperAsset],
        showCategory: Bool = true,
        seeAll: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeading(title: title, subtitle: subtitle, action: seeAll)
                .padding(.horizontal, 28)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 16) {
                    ForEach(assets) { asset in
                        WallpaperTile(
                            model: model,
                            asset: asset,
                            width: 268,
                            showCategory: showCategory
                        )
                    }
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 10)
            }
        }
    }
}

struct FeaturedHero: View {
    @Bindable var model: AppModel
    @State private var slideIndex = 0
    /// False while the window is behind other apps, minimized, or on another
    /// Space. The slideshow stops then: each advance builds a new video player
    /// and redraws the shadowed title on the CPU.
    @State private var isOnScreen = false

    private static let slideDuration: Duration = .seconds(4)

    private struct SlideshowKey: Equatable {
        var count: Int
        var isOnScreen: Bool
    }

    private var assets: [WallpaperAsset] { model.assets }
    private var currentAsset: WallpaperAsset? {
        guard !assets.isEmpty else { return nil }
        return assets[slideIndex % assets.count]
    }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            slideshowBackground

            LinearGradient(
                colors: [.clear, .black.opacity(0.35), .black.opacity(0.92)],
                startPoint: .top,
                endPoint: .bottom
            )

            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 9) {
                    BrandMark(size: 24)
                    Text(currentAsset == nil ? "YOUR WALLPAPER, IN MOTION" : statusLabel)
                        .font(.system(size: 11, weight: .bold))
                        .tracking(1.6)
                        .foregroundStyle(Theme.accent)
                }
                Text(currentAsset?.name ?? "Make your desktop feel alive.")
                    .font(.system(size: 40, weight: .bold, design: .rounded))
                    .lineLimit(2)
                    .shadow(color: .black.opacity(0.5), radius: 10, y: 2)
                Text(currentAsset.map(meta) ?? "Private local video wallpapers. Import once, apply instantly, stay offline.")
                    .font(.system(size: 14))
                    .foregroundStyle(.white.opacity(0.72))
                    .frame(maxWidth: 520, alignment: .leading)
                HStack(spacing: 10) {
                    if let currentAsset {
                        PrimaryButton("Use as Wallpaper", symbol: "display") { model.apply(currentAsset) }
                        GhostButton("All Displays", symbol: "rectangle.on.rectangle") { model.applyToAll(currentAsset) }
                        GhostButton("Preview", symbol: "play.fill") { model.previewAsset = currentAsset }
                    } else {
                        PrimaryButton("Import your first wallpaper", symbol: "plus", action: model.chooseVideos)
                    }
                }
            }
            .padding(.horizontal, 36)
            .padding(.bottom, 36)
            .frame(maxWidth: 760, alignment: .leading)

            if assets.count > 1 {
                slideIndicators
                    .padding(.trailing, 36)
                    .padding(.bottom, 36)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 420)
        .onAppear { syncSlideIndex() }
        .onChange(of: assets.map(\.id)) { _, _ in
            syncSlideIndex()
        }
        .background(WindowVisibilityReader { visible in
            if isOnScreen != visible { isOnScreen = visible }
        })
        // Auto-cancelled by SwiftUI on disappear / count / visibility change.
        // Keyed on the count (not the ID list) so metadata reloads from
        // apply/recordApply don't restart the 4s cadence and make the hero jitter.
        .task(id: SlideshowKey(count: assets.count, isOnScreen: isOnScreen && !model.screenIsHidden)) {
            guard isOnScreen, !model.screenIsHidden, assets.count > 1 else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.slideDuration)
                guard !Task.isCancelled else { break }
                // No withAnimation: the background and indicators carry their
                // own animations. Animating the whole hero crossfaded the
                // shadowed title on the CPU at every advance.
                slideIndex = (slideIndex + 1) % assets.count
            }
        }
    }

    @ViewBuilder
    private var slideshowBackground: some View {
        ZStack {
            if let asset = currentAsset {
                LoopingVideoView(
                    url: NativeWallpaperDeployment.previewURL(for: asset, minPixelWidth: NativeWallpaperDeployment.PreviewSize.hero),
                    isSuspended: model.screenIsHidden
                )
                    .id(asset.id)
                    .transition(.opacity)
            } else {
                LinearGradient(
                    colors: [
                        Color(red: 0.06, green: 0.18, blue: 0.20),
                        Color(red: 0.03, green: 0.06, blue: 0.09),
                        Color(red: 0.02, green: 0.04, blue: 0.06)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .overlay(alignment: .trailing) {
                    BrandMark(size: 200, glowing: false)
                        .opacity(0.10)
                        .offset(x: -28, y: -20)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 420)
        .clipped()
        .animation(.easeInOut(duration: 0.7), value: slideIndex)
    }

    private var slideIndicators: some View {
        HStack(spacing: 6) {
            ForEach(Array(assets.enumerated()), id: \.element.id) { index, _ in
                Capsule()
                    .fill(index == slideIndex % assets.count ? Theme.accent : .white.opacity(0.28))
                    .frame(width: index == slideIndex % assets.count ? 18 : 6, height: 6)
                    .animation(.snappy(duration: 0.25), value: slideIndex)
                    .onTapGesture {
                        withAnimation(.easeInOut(duration: 0.7)) {
                            slideIndex = index
                        }
                    }
            }
        }
        .accessibilityLabel("Wallpaper \(slideIndex + 1) of \(assets.count)")
    }

    private var statusLabel: String {
        guard let currentAsset else { return "FEATURED" }
        if model.isActive(currentAsset) { return "NOW PLAYING" }
        if assets.count > 1 { return "PREVIEWING \(slideIndex + 1) OF \(assets.count)" }
        return "FEATURED FROM YOUR LIBRARY"
    }

    private func meta(_ asset: WallpaperAsset) -> String {
        "\(Int(asset.pixelSize.width)) × \(Int(asset.pixelSize.height))  ·  \(Int(asset.framesPerSecond)) FPS  ·  \(asset.category.title)"
    }

    private func syncSlideIndex() {
        guard !assets.isEmpty else {
            slideIndex = 0
            return
        }
        if slideIndex >= assets.count {
            slideIndex = 0
        }
        if let featured = model.featured,
           let index = assets.firstIndex(where: { $0.id == featured.id }) {
            slideIndex = index
        }
    }
}
