import AppKit
import LumaWallCore
import SwiftUI

@main
struct LumaWallApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup("LumaWall") {
            RootView(model: model)
                .frame(minWidth: 980, minHeight: 640)
        }
        .defaultSize(width: 1_220, height: 780)
        .windowStyle(.hiddenTitleBar)

        MenuBarExtra("LumaWall", systemImage: "sparkles.rectangle.stack") {
            MenuBarRoot(model: model)
        }
        .menuBarExtraStyle(.window)
    }
}

enum Theme {
    static let bg = Color(red: 0.05, green: 0.07, blue: 0.09)
    static let panel = Color.white.opacity(0.05)
    static let line = Color.white.opacity(0.08)
    static let accent = Color(red: 0.18, green: 0.78, blue: 0.72)
    static let warm = Color(red: 0.98, green: 0.72, blue: 0.42)
}

private struct RootView: View {
    @Bindable var model: AppModel

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            VStack(spacing: 0) {
                Chrome(model: model)
                Divider().overlay(Theme.line)
                Group {
                    switch model.section {
                    case .home: HomePage(model: model)
                    case .explore: ExplorePage(model: model)
                    case .library: LibraryPage(model: model)
                    case .displays: DisplaysPage(model: model)
                    case .playlists: PlaylistsPage(model: model)
                    case .settings: SettingsPage(model: model)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .preferredColorScheme(.dark)
        .tint(Theme.accent)
        .dropDestination(for: URL.self) { urls, _ in model.importVideos(urls); return true }
        .alert(model.alertTitle, isPresented: $model.showsAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.alertMessage)
        }
        .sheet(item: $model.previewAsset) { PreviewSheet(asset: $0) }
        .sheet(item: $model.assignTarget) { display in
            AssignSheet(model: model, display: display)
        }
        .overlay {
            if model.isImporting || model.isApplying {
                BusyOverlay(text: model.isImporting ? "Preparing wallpaper…" : "Applying to desktop…")
            }
        }
        .onAppear { model.refreshDisplays() }
    }
}

private struct Chrome: View {
    @Bindable var model: AppModel

    var body: some View {
        HStack(spacing: 14) {
            Button { model.section = .home } label: {
                HStack(spacing: 10) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Theme.accent)
                        Image(systemName: "waveform.path").font(.system(size: 15, weight: .bold)).foregroundStyle(.black)
                    }
                    .frame(width: 34, height: 34)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("LumaWall").font(.system(size: 15, weight: .bold, design: .rounded))
                        Text(model.isPaused ? "Paused" : "Live").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                    }
                }
            }
            .buttonStyle(.plain)

            HStack(spacing: 2) {
                ForEach([AppModel.Section.home, .explore, .library]) { item in
                    Button {
                        model.section = item
                    } label: {
                        Text(item.title)
                            .font(.system(size: 12, weight: model.section == item ? .semibold : .medium))
                            .padding(.horizontal, 12)
                            .frame(height: 32)
                            .background {
                                if model.section == item {
                                    Capsule().fill(.white)
                                }
                            }
                            .foregroundStyle(model.section == item ? .black : .white.opacity(0.65))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(3)
            .background(.black.opacity(0.28), in: Capsule())
            .overlay(Capsule().stroke(Theme.line))

            Spacer()

            iconNav(.displays, "display.2")
            iconNav(.playlists, "rectangle.stack.fill")
            iconNav(.settings, "gearshape.fill")

            Button(action: model.togglePause) {
                Image(systemName: model.isPaused ? "play.fill" : "pause.fill")
                    .frame(width: 34, height: 34)
                    .background(.white.opacity(0.08), in: Circle())
            }
            .buttonStyle(.plain)
            .help(model.isPaused ? "Resume wallpapers" : "Pause wallpapers")

            Button(action: model.chooseVideos) {
                Image(systemName: "plus")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 34, height: 34)
                    .background(Theme.accent.opacity(0.9), in: Circle())
                    .foregroundStyle(.black)
            }
            .buttonStyle(.plain)
            .help("Import videos")
        }
        .padding(.horizontal, 20)
        .frame(height: 62)
        .background(.black.opacity(0.2))
    }

    private func iconNav(_ section: AppModel.Section, _ symbol: String) -> some View {
        Button { model.section = section } label: {
            Image(systemName: symbol)
                .frame(width: 34, height: 34)
                .background(model.section == section ? .white : .white.opacity(0.08), in: Circle())
                .foregroundStyle(model.section == section ? .black : .white.opacity(0.7))
        }
        .buttonStyle(.plain)
        .help(section.title)
    }
}

// MARK: - Home (cinematic now-playing)

private struct HomePage: View {
    @Bindable var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                FeaturedHero(model: model)
                if !model.assets.isEmpty {
                    sectionHeader("Now in your library", "Tap Apply to put motion on the desktop")
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 14) {
                            ForEach(model.assets.reversed()) { asset in
                                CompactCard(model: model, asset: asset).frame(width: 240)
                            }
                        }
                    }
                } else {
                    EmptyInvite(action: model.chooseVideos)
                }
                HStack(spacing: 14) {
                    QuickTile(symbol: "display.2", title: "Displays", detail: "\(model.displays.count) connected", color: Theme.accent) {
                        model.section = .displays
                    }
                    QuickTile(symbol: "rectangle.stack.fill", title: "Playlists", detail: "\(model.playlists.count) saved", color: Theme.warm) {
                        model.section = .playlists
                    }
                    QuickTile(symbol: "leaf.fill", title: "Energy", detail: model.powerProfile.label, color: .green) {
                        model.section = .settings
                    }
                }
            }
            .padding(24)
        }
    }
}

private struct FeaturedHero: View {
    @Bindable var model: AppModel
    var asset: WallpaperAsset? { model.featured }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottomLeading) {
                Group {
                    if let url = asset?.posterURL, let image = NSImage(contentsOf: url) {
                        Image(nsImage: image).resizable().scaledToFill()
                    } else {
                        LinearGradient(
                            colors: [Color(red: 0.08, green: 0.22, blue: 0.24), Color(red: 0.05, green: 0.08, blue: 0.12)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height)
                .clipped()

                LinearGradient(colors: [.clear, .black.opacity(0.82)], startPoint: .center, endPoint: .bottom)

                VStack(alignment: .leading, spacing: 12) {
                    Text(asset == nil ? "START HERE" : (model.isActive(asset!) ? "NOW PLAYING" : "FEATURED"))
                        .font(.system(size: 11, weight: .bold))
                        .tracking(1.6)
                        .foregroundStyle(Theme.accent)
                    Text(asset?.name ?? "Import a video and apply it as your wallpaper.")
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .lineLimit(2)
                    if let asset {
                        Text("\(Int(asset.pixelSize.width))×\(Int(asset.pixelSize.height))  ·  \(Int(asset.framesPerSecond)) FPS  ·  Local")
                            .foregroundStyle(.white.opacity(0.7))
                    }
                    HStack(spacing: 10) {
                        if let asset {
                            Button("Apply to Main Display", systemImage: "display") { model.apply(asset) }
                                .buttonStyle(.borderedProminent)
                                .tint(Theme.accent)
                                .foregroundStyle(.black)
                            Button("Apply to All", systemImage: "rectangle.on.rectangle") { model.applyToAll(asset) }
                                .buttonStyle(.bordered)
                            Button("Preview", systemImage: "play.fill") { model.previewAsset = asset }
                                .buttonStyle(.bordered)
                        } else {
                            Button("Import Wallpaper", systemImage: "plus", action: model.chooseVideos)
                                .buttonStyle(.borderedProminent)
                                .tint(Theme.accent)
                                .foregroundStyle(.black)
                        }
                    }
                    .controlSize(.large)
                }
                .padding(28)
            }
        }
        .frame(height: 360)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24).stroke(Theme.line))
    }
}

// MARK: - Explore (search-first mosaic)

private struct ExplorePage: View {
    @Bindable var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Explore").font(.system(size: 34, weight: .bold, design: .rounded))
                    Text("Search your private collection. Nothing leaves this Mac.")
                        .foregroundStyle(.secondary)
                    HStack(spacing: 10) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("Mood, title, resolution…", text: $model.searchText)
                            .textFieldStyle(.plain)
                        if !model.searchText.isEmpty {
                            Button { model.searchText = "" } label: {
                                Image(systemName: "xmark.circle.fill")
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 14)
                    .frame(height: 42)
                    .background(.black.opacity(0.28), in: Capsule())
                    .overlay(Capsule().stroke(Theme.line))

                    HStack(spacing: 8) {
                        ForEach(AppModel.LibraryFilter.allCases) { filter in
                            FilterChip(title: filter.rawValue, selected: model.libraryFilter == filter) {
                                model.libraryFilter = filter
                            }
                        }
                    }
                }
                .padding(22)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    LinearGradient(colors: [Theme.accent.opacity(0.18), .clear], startPoint: .topLeading, endPoint: .bottomTrailing),
                    in: RoundedRectangle(cornerRadius: 22, style: .continuous)
                )
                .overlay(RoundedRectangle(cornerRadius: 22).stroke(Theme.line))

                Text(model.searchText.isEmpty ? "\(model.filteredAssets.count) wallpapers" : "\(model.filteredAssets.count) matches")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)

                if model.filteredAssets.isEmpty {
                    EmptyInvite(action: model.chooseVideos)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 210, maximum: 320), spacing: 16)], spacing: 16) {
                        ForEach(model.filteredAssets) { asset in
                            MosaicCard(model: model, asset: asset)
                        }
                    }
                }
            }
            .padding(24)
        }
    }
}

// MARK: - Library (management)

private struct LibraryPage: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Library").font(.system(size: 28, weight: .bold, design: .rounded))
                    Text("\(model.assets.count) installed · manage, apply, remove")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Import", systemImage: "plus", action: model.chooseVideos)
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
                    .foregroundStyle(.black)
            }
            .padding(24)

            HStack(spacing: 8) {
                ForEach(AppModel.LibraryFilter.allCases) { filter in
                    FilterChip(title: filter.rawValue, selected: model.libraryFilter == filter) {
                        model.libraryFilter = filter
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 12)

            if model.filteredAssets.isEmpty {
                EmptyInvite(action: model.chooseVideos).padding(24)
                Spacer()
            } else {
                List {
                    ForEach(model.filteredAssets) { asset in
                        LibraryRow(model: model, asset: asset)
                            .listRowBackground(Theme.panel)
                            .listRowSeparatorTint(Theme.line)
                    }
                }
                .scrollContentBackground(.hidden)
                .listStyle(.inset)
            }
        }
    }
}

private struct LibraryRow: View {
    @Bindable var model: AppModel
    let asset: WallpaperAsset

    var body: some View {
        HStack(spacing: 14) {
            poster.frame(width: 96, height: 60).clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(asset.name).font(.headline).lineLimit(1)
                    if model.isActive(asset) {
                        Text("LIVE").font(.system(size: 9, weight: .bold))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Theme.accent.opacity(0.2), in: Capsule())
                            .foregroundStyle(Theme.accent)
                    }
                }
                Text("\(Int(asset.pixelSize.width))×\(Int(asset.pixelSize.height)) · \(Int(asset.framesPerSecond)) FPS")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button { model.toggleFavorite(asset) } label: {
                Image(systemName: model.isFavorite(asset) ? "heart.fill" : "heart")
                    .foregroundStyle(model.isFavorite(asset) ? .pink : .secondary)
            }
            .buttonStyle(.plain)
            Button("Preview") { model.previewAsset = asset }.buttonStyle(.bordered)
            Menu("Apply") {
                Button("Main Display") { model.apply(asset) }
                Button("All Displays") { model.applyToAll(asset) }
                Divider()
                ForEach(model.displays) { display in
                    Button(display.name) { model.apply(asset, to: display.displayID) }
                }
            }
            .menuStyle(.borderlessButton)
            Button(role: .destructive) { model.remove(asset) } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder private var poster: some View {
        if let url = asset.posterURL, let image = NSImage(contentsOf: url) {
            Image(nsImage: image).resizable().scaledToFill()
        } else {
            Rectangle().fill(.white.opacity(0.06))
        }
    }
}

// MARK: - Displays

private struct DisplaysPage: View {
    @Bindable var model: AppModel

    private var bounds: CGRect {
        model.displays.map(\.frame).reduce(CGRect.null) { $0.union($1) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Displays").font(.system(size: 28, weight: .bold, design: .rounded))
                        Text("Assign a different wallpaper to every screen.")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Refresh", systemImage: "arrow.clockwise") { model.refreshDisplays() }
                        .buttonStyle(.bordered)
                }

                topology
                    .frame(height: 220)
                    .padding(18)
                    .background(Theme.panel, in: RoundedRectangle(cornerRadius: 20))
                    .overlay(RoundedRectangle(cornerRadius: 20).stroke(Theme.line))

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 16)], spacing: 16) {
                    ForEach(model.displays) { display in
                        DisplayCard(model: model, display: display)
                    }
                }
            }
            .padding(24)
        }
        .onAppear { model.refreshDisplays() }
    }

    private var topology: some View {
        GeometryReader { geo in
            let world = bounds.isNull ? CGRect(x: 0, y: 0, width: 1, height: 1) : bounds
            let scale = min(geo.size.width / max(world.width, 1), geo.size.height / max(world.height, 1)) * 0.82
            let offsetX = (geo.size.width - world.width * scale) / 2 - world.minX * scale
            let offsetY = (geo.size.height - world.height * scale) / 2 - world.minY * scale

            ZStack(alignment: .topLeading) {
                ForEach(model.displays) { display in
                    let rect = CGRect(
                        x: display.frame.minX * scale + offsetX,
                        y: (world.maxY - display.frame.maxY) * scale + offsetY,
                        width: display.frame.width * scale,
                        height: display.frame.height * scale
                    )
                    let live = model.activeByDisplay[display.displayID] != nil
                    RoundedRectangle(cornerRadius: 8)
                        .fill(live ? Theme.accent.opacity(0.25) : .white.opacity(0.06))
                        .overlay {
                            VStack(spacing: 4) {
                                Text(display.name).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                                Text(live ? "Playing" : "Idle").font(.system(size: 10)).foregroundStyle(.secondary)
                            }
                            .padding(6)
                        }
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(live ? Theme.accent : Theme.line, lineWidth: live ? 2 : 1))
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                }
            }
        }
    }
}

private struct DisplayCard: View {
    @Bindable var model: AppModel
    let display: ConnectedDisplay

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(display.isMain ? "MAIN · \(display.name)" : display.name)
                        .font(.headline)
                    Text("\(Int(display.pixelSize.width))×\(Int(display.pixelSize.height)) · \(Int(display.refreshRate)) Hz")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Circle().fill(model.activeByDisplay[display.displayID] == nil ? Color.white.opacity(0.2) : Theme.accent)
                    .frame(width: 10, height: 10)
            }
            Text(model.activeName(on: display) ?? "No wallpaper assigned")
                .font(.subheadline)
                .foregroundStyle(model.activeName(on: display) == nil ? .secondary : .primary)
                .lineLimit(1)
            HStack {
                Button("Choose…") { model.assignTarget = display }.buttonStyle(.borderedProminent).tint(Theme.accent).foregroundStyle(.black)
                if model.activeByDisplay[display.displayID] != nil {
                    Button("Clear") { model.clearDisplay(display) }.buttonStyle(.bordered)
                }
            }
        }
        .padding(16)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Theme.line))
    }
}

// MARK: - Playlists

private struct PlaylistsPage: View {
    @Bindable var model: AppModel
    @State private var draftName = ""
    @State private var useFavoritesOnly = true
    @State private var shuffled = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Playlists").font(.system(size: 28, weight: .bold, design: .rounded))
                    Text("Rotate wallpapers without keeping this window open.")
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 12) {
                    Text("Create").font(.headline)
                    TextField("Name", text: $draftName).textFieldStyle(.roundedBorder)
                    Toggle("Use favorites only", isOn: $useFavoritesOnly)
                    Toggle("Shuffle order", isOn: $shuffled)
                    Button("Create Playlist") {
                        let source = useFavoritesOnly
                            ? model.assets.filter { model.isFavorite($0) }
                            : model.assets
                        model.createPlaylist(name: draftName, from: source, shuffled: shuffled)
                        draftName = ""
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
                    .foregroundStyle(.black)
                    .disabled(model.assets.isEmpty)
                }
                .padding(18)
                .background(Theme.panel, in: RoundedRectangle(cornerRadius: 18))
                .overlay(RoundedRectangle(cornerRadius: 18).stroke(Theme.line))

                if model.playlists.isEmpty {
                    Text("No playlists yet. Favorite a few wallpapers, then create one.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.playlists) { playlist in
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(playlist.name).font(.headline)
                                Text("\(playlist.wallpaperIDs.count) items · \(playlist.shuffled ? "Shuffled" : "Ordered") · every \(playlist.intervalMinutes)m")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Apply") { model.applyPlaylist(playlist) }.buttonStyle(.borderedProminent).tint(Theme.accent).foregroundStyle(.black)
                            Button("Delete", role: .destructive) { model.deletePlaylist(playlist) }
                        }
                        .padding(16)
                        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 16))
                        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Theme.line))
                    }
                }
            }
            .padding(24)
        }
    }
}

// MARK: - Settings

private struct SettingsPage: View {
    @Bindable var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text("Settings").font(.system(size: 28, weight: .bold, design: .rounded))
                Text("Quiet defaults with precise control when you need it.")
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 12) {
                    Text("Energy profile").font(.headline)
                    ForEach(PowerProfile.allCases, id: \.self) { profile in
                        Button {
                            model.setPowerProfile(profile)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(profile.label).font(.subheadline.weight(.semibold))
                                    Text(profile.detail).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if model.powerProfile == profile {
                                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.accent)
                                }
                            }
                            .padding(14)
                            .background(model.powerProfile == profile ? Theme.accent.opacity(0.12) : Theme.panel, in: RoundedRectangle(cornerRadius: 14))
                            .overlay(RoundedRectangle(cornerRadius: 14).stroke(model.powerProfile == profile ? Theme.accent.opacity(0.5) : Theme.line))
                        }
                        .buttonStyle(.plain)
                    }
                }

                Toggle("Pause when the desktop is hidden", isOn: $model.pauseWhenObscured)
                    .onChange(of: model.pauseWhenObscured) { _, value in
                        UserDefaults.standard.set(value, forKey: "lumawall.pauseWhenObscured")
                    }
                    .padding(14)
                    .background(Theme.panel, in: RoundedRectangle(cornerRadius: 14))

                VStack(alignment: .leading, spacing: 8) {
                    Text("Local only").font(.headline)
                    Text("Filenames, videos, favorites, and display assignments stay on this Mac. LumaWall has no account requirement.")
                        .foregroundStyle(.secondary)
                }
                .padding(16)
                .background(Theme.panel, in: RoundedRectangle(cornerRadius: 16))
            }
            .padding(24)
        }
    }
}

// MARK: - Shared pieces

private struct CompactCard: View {
    @Bindable var model: AppModel
    let asset: WallpaperAsset

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack(alignment: .topTrailing) {
                poster.aspectRatio(16 / 10, contentMode: .fill).clipped().clipShape(RoundedRectangle(cornerRadius: 14))
                Button { model.toggleFavorite(asset) } label: {
                    Image(systemName: model.isFavorite(asset) ? "heart.fill" : "heart")
                        .foregroundStyle(model.isFavorite(asset) ? .pink : .white)
                        .frame(width: 28, height: 28)
                        .background(.black.opacity(0.45), in: Circle())
                }
                .buttonStyle(.plain)
                .padding(8)
            }
            Text(asset.name).font(.subheadline.weight(.semibold)).lineLimit(1)
            HStack {
                Button("Apply") { model.apply(asset) }.buttonStyle(.borderedProminent).tint(Theme.accent).foregroundStyle(.black).controlSize(.small)
                Button("Preview") { model.previewAsset = asset }.buttonStyle(.bordered).controlSize(.small)
            }
        }
        .padding(10)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Theme.line))
    }

    @ViewBuilder private var poster: some View {
        if let url = asset.posterURL, let image = NSImage(contentsOf: url) {
            Image(nsImage: image).resizable().scaledToFill()
        } else { Rectangle().fill(.white.opacity(0.06)) }
    }
}

private struct MosaicCard: View {
    @Bindable var model: AppModel
    let asset: WallpaperAsset
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                poster.aspectRatio(16 / 10, contentMode: .fill).clipped()
                if hovering {
                    Color.black.opacity(0.35)
                    HStack(spacing: 8) {
                        Button("Apply") { model.apply(asset) }.buttonStyle(.borderedProminent).tint(Theme.accent).foregroundStyle(.black)
                        Button("Preview") { model.previewAsset = asset }.buttonStyle(.bordered)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .onHover { hovering = $0 }
            Text(asset.name).font(.subheadline.weight(.semibold)).lineLimit(1)
            Text("\(Int(asset.pixelSize.width))×\(Int(asset.pixelSize.height))").font(.caption2).foregroundStyle(.secondary)
        }
        .onTapGesture { model.previewAsset = asset }
    }

    @ViewBuilder private var poster: some View {
        if let url = asset.posterURL, let image = NSImage(contentsOf: url) {
            Image(nsImage: image).resizable().scaledToFill()
        } else { Rectangle().fill(.white.opacity(0.06)) }
    }
}

private struct AssignSheet: View {
    @Bindable var model: AppModel
    let display: ConnectedDisplay
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Assign to \(display.name)").font(.title2.bold())
            if model.assets.isEmpty {
                Text("Import a wallpaper first.").foregroundStyle(.secondary)
            } else {
                List(model.assets) { asset in
                    Button {
                        model.apply(asset, to: display.displayID)
                        dismiss()
                    } label: {
                        HStack {
                            Text(asset.name)
                            Spacer()
                            if model.activeByDisplay[display.displayID] == asset.id {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            Button("Close", action: dismiss.callAsFunction)
        }
        .padding(20)
        .frame(width: 420, height: 480)
    }
}

private struct PreviewSheet: View {
    let asset: WallpaperAsset
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            LoopingVideoView(url: asset.mediaURL)
                .aspectRatio(16 / 9, contentMode: .fit)
                .background(.black)
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(asset.name).font(.title3.bold())
                    Text("\(Int(asset.pixelSize.width))×\(Int(asset.pixelSize.height)) · \(Int(asset.framesPerSecond)) FPS")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done", action: dismiss.callAsFunction).keyboardShortcut(.cancelAction)
            }
            .padding(16)
        }
        .frame(width: 900, height: 580)
    }
}

private struct MenuBarRoot: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("LumaWall").font(.headline)
            if let featured = model.featured {
                Text(featured.name).lineLimit(1)
                HStack {
                    Button(model.isPaused ? "Resume" : "Pause", action: model.togglePause)
                    Button("Apply All") { model.applyToAll(featured) }
                }
            } else {
                Text("No wallpaper yet").foregroundStyle(.secondary)
            }
            Divider()
            Button("Open LumaWall") { model.section = .home; NSApp.activate(ignoringOtherApps: true) }
            Button("Displays") { model.section = .displays; NSApp.activate(ignoringOtherApps: true) }
            Button("Import…", action: model.chooseVideos)
        }
        .padding(14)
        .frame(width: 260)
    }
}

private struct FilterChip: View {
    let title: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 12)
                .frame(height: 30)
                .background(selected ? .white : .white.opacity(0.06), in: Capsule())
                .foregroundStyle(selected ? .black : .white.opacity(0.72))
        }
        .buttonStyle(.plain)
    }
}

private struct QuickTile: View {
    let symbol: String, title: String, detail: String, color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: symbol).foregroundStyle(color).font(.title3)
                Text(title).font(.headline)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 96, alignment: .topLeading)
            .padding(16)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Theme.line))
        }
        .buttonStyle(.plain)
    }
}

private struct EmptyInvite: View {
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: "plus").font(.title2).frame(width: 48, height: 48).background(.white.opacity(0.08), in: Circle())
                VStack(alignment: .leading, spacing: 4) {
                    Text("Add your first wallpaper").font(.headline)
                    Text("Drop an MP4 or MOV anywhere in this window").foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(18)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(style: StrokeStyle(lineWidth: 1, dash: [6])))
        }
        .buttonStyle(.plain)
    }
}

private struct BusyOverlay: View {
    let text: String
    var body: some View {
        ZStack {
            Color.black.opacity(0.45).ignoresSafeArea()
            VStack(spacing: 12) {
                ProgressView().controlSize(.large)
                Text(text).fontWeight(.semibold)
            }
            .padding(28)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        }
    }
}

private func sectionHeader(_ title: String, _ subtitle: String) -> some View {
    VStack(alignment: .leading, spacing: 3) {
        Text(title).font(.system(size: 20, weight: .bold, design: .rounded))
        Text(subtitle).font(.caption).foregroundStyle(.secondary)
    }
}

private extension PowerProfile {
    var label: String {
        switch self {
        case .automatic: "Automatic"
        case .fullQuality: "Full Quality"
        case .batterySaver: "Battery Saver"
        case .staticOnBattery: "Static on Battery"
        }
    }

    var detail: String {
        switch self {
        case .automatic: "Full fidelity on power, adaptive on battery."
        case .fullQuality: "Prefer source frame rate whenever possible."
        case .batterySaver: "Use the lowest animated tier on battery."
        case .staticOnBattery: "Hold a still frame until power returns."
        }
    }
}

