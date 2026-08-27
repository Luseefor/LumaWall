import AppKit
import LumaWallCore
import SwiftUI

@main
struct LumaWallApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup("LumaWall") {
            RootView(model: model)
                .frame(minWidth: 1_080, minHeight: 700)
        }
        .defaultSize(width: 1_280, height: 840)
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unifiedCompact)

        MenuBarExtra {
            MenuBarRoot(model: model)
        } label: {
            BrandMark(size: 15, glowing: false)
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

private struct RootView: View {
    @Bindable var model: AppModel

    var body: some View {
        ZStack {
            AtmosphereBackground()
            VStack(spacing: 0) {
                PhospheneChrome(model: model)
                Rectangle().fill(Theme.line).frame(height: 1)
                content
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
        .sheet(item: $model.previewAsset) { PreviewSheet(model: model, asset: $0) }
        .sheet(item: $model.assignTarget) { AssignSheet(model: model, display: $0) }
        .sheet(item: $model.automationPickSlot) { slot in
            AutomationPickSheet(model: model, slot: slot)
        }
        .sheet(item: $model.playlistEditor) { _ in
            PlaylistEditorSheet(model: model)
        }
        .overlay {
            if model.isImporting || model.isApplying {
                BusyOverlay(text: model.isImporting ? "Preparing wallpaper…" : "Applying to desktop…")
            }
        }
        .onAppear { model.refreshDisplays() }
    }

    @ViewBuilder private var content: some View {
        switch model.section {
        case .home: HomePage(model: model)
        case .library: LibraryPage(model: model)
        case .displays: DisplaysPage(model: model)
        case .settings: SettingsPage(model: model)
        }
    }
}

private struct AtmosphereBackground: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [Theme.bgTop, Theme.bgBottom], startPoint: .topLeading, endPoint: .bottomTrailing)
            Circle()
                .fill(Theme.accent.opacity(0.11))
                .frame(width: 560, height: 560)
                .blur(radius: 110)
                .offset(x: 380, y: -260)
            Circle()
                .fill(Theme.warm.opacity(0.045))
                .frame(width: 480, height: 480)
                .blur(radius: 100)
                .offset(x: -320, y: 300)
            LinearGradient(
                colors: [.white.opacity(0.03), .clear, .white.opacity(0.015)],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .ignoresSafeArea()
    }
}

// MARK: - Top chrome

private struct PhospheneChrome: View {
    @Bindable var model: AppModel

    var body: some View {
        HStack(spacing: 16) {
            Button { model.section = .home } label: {
                HStack(spacing: 10) {
                    BrandMark(size: 34)
                    Text("LumaWall")
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                }
                .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .help("Home")

            HStack(spacing: 3) {
                ForEach(AppModel.Section.allCases) { item in
                    Button {
                        withAnimation(.snappy(duration: 0.24)) { model.section = item }
                    } label: {
                        Text(item.title)
                            .font(.system(size: 12, weight: model.section == item ? .semibold : .medium))
                            .padding(.horizontal, 12)
                            .frame(height: 34)
                            .background {
                                if model.section == item {
                                    Capsule().fill(.white.opacity(0.94))
                                }
                            }
                            .foregroundStyle(model.section == item ? Color.black : Color.white.opacity(0.68))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(4)
            .background(.black.opacity(0.24), in: Capsule())
            .overlay(Capsule().stroke(Theme.line))

            Spacer(minLength: 10)

            LibrarySearchField(text: $model.searchText, onSubmit: { model.section = .library })
                .frame(width: 188, height: 28)
                .padding(.horizontal, 10)
                .frame(height: 36)
                .background(.white.opacity(0.06), in: Capsule())
                .overlay(Capsule().stroke(Theme.line))
                .onChange(of: model.searchText) { _, value in
                    if !value.isEmpty, model.section != .library {
                        model.section = .library
                    }
                }

            Button(action: model.togglePause) {
                Image(systemName: model.isPaused ? "play.fill" : "pause.fill")
                    .frame(width: 36, height: 36)
                    .background(.white.opacity(0.10), in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help(model.isPaused ? "Resume" : "Pause")

            Button(action: model.chooseVideos) {
                Image(systemName: "plus")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 36, height: 36)
                    .background(.white.opacity(0.10), in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Import videos")
        }
        .padding(.horizontal, 24)
        .padding(.top, 28)
        .padding(.bottom, 10)
        .background(.black.opacity(0.12))
        .background(ChromeHitSurface())
    }
}

/// Hidden-title-bar windows put this chrome under the drag region. This view
/// claims mouse events so search, pause, and import actually receive clicks.
private struct ChromeHitSurface: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { ChromeHitView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

private final class ChromeHitView: NSView {
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.styleMask.insert(.fullSizeContentView)
        window.isMovableByWindowBackground = true
        window.toolbar = nil
    }
}

private struct LibrarySearchField: NSViewRepresentable {
    @Binding var text: String
    var onSubmit: () -> Void

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = "Search library"
        field.focusRingType = .none
        field.bezelStyle = .roundedBezel
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.font = .systemFont(ofSize: 13)
        field.delegate = context.coordinator
        field.target = context.coordinator
        field.action = #selector(Coordinator.submitted(_:))
        return field
    }

    func updateNSView(_ nsView: NSSearchField, context: Context) {
        context.coordinator.parent = self
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    @MainActor
    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: LibrarySearchField
        init(_ parent: LibrarySearchField) { self.parent = parent }

        func controlTextDidChange(_ obj: Notification) {
            parent.text = (obj.object as? NSSearchField)?.stringValue ?? ""
        }

        @objc func submitted(_ sender: NSSearchField) {
            parent.text = sender.stringValue
            parent.onSubmit()
        }
    }
}

// MARK: - Home

private struct HomePage: View {
    @Bindable var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                FeaturedHero(model: model)

                if model.assets.isEmpty {
                    EmptyInvite(action: model.chooseVideos)
                        .padding(.horizontal, 28)
                } else {
                    horizontalRow(
                        title: "Recently added",
                        subtitle: "One click puts motion on your desktop",
                        assets: Array(model.assets.prefix(8)),
                        seeAll: { model.section = .library }
                    )

                    if !model.recentAssets.isEmpty {
                        horizontalRow(
                            title: "Recents",
                            subtitle: "Wallpapers you’ve applied lately",
                            assets: Array(model.recentAssets.prefix(8)),
                            seeAll: { model.section = .library }
                        )
                    }

                    if !model.likedAssets.isEmpty {
                        horizontalRow(
                            title: "Favorites",
                            subtitle: "Hearted wallpapers from this Mac",
                            assets: Array(model.likedAssets.prefix(8)),
                            seeAll: { model.section = .library }
                        )
                    }

                    ForEach(WallpaperCategory.allCases) { category in
                        let items = model.assets(in: category)
                        if !items.isEmpty {
                            horizontalRow(
                                title: category.title,
                                subtitle: "\(items.count) local",
                                assets: Array(items.prefix(8)),
                                showCategory: false,
                                seeAll: { model.section = .library }
                            )
                        }
                    }
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
                HStack(spacing: 16) {
                    ForEach(assets) { asset in
                        WallpaperTile(
                            model: model,
                            asset: asset,
                            width: 268,
                            style: .cinematic,
                            showCategory: showCategory
                        )
                    }
                }
                .padding(.horizontal, 28)
            }
        }
    }
}

private struct FeaturedHero: View {
    @Bindable var model: AppModel
    private var asset: WallpaperAsset? { model.featured }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Group {
                if let url = asset?.posterURL, let image = NSImage(contentsOf: url) {
                    Image(nsImage: image).resizable().scaledToFill()
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

            LinearGradient(
                colors: [.clear, .black.opacity(0.35), .black.opacity(0.92)],
                startPoint: .top,
                endPoint: .bottom
            )

            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 9) {
                    BrandMark(size: 24)
                    Text(asset == nil ? "YOUR WALLPAPER, IN MOTION" : statusLabel)
                        .font(.system(size: 11, weight: .bold))
                        .tracking(1.6)
                        .foregroundStyle(Theme.accent)
                }
                Text(asset?.name ?? "Make your desktop feel alive.")
                    .font(.system(size: 40, weight: .bold, design: .rounded))
                    .lineLimit(2)
                    .shadow(color: .black.opacity(0.5), radius: 10, y: 2)
                Text(asset.map(meta) ?? "Private local video wallpapers. Import once, apply instantly, stay offline.")
                    .font(.system(size: 14))
                    .foregroundStyle(.white.opacity(0.72))
                    .frame(maxWidth: 520, alignment: .leading)
                HStack(spacing: 10) {
                    if let asset {
                        PrimaryButton("Use as Wallpaper", symbol: "display") { model.apply(asset) }
                        GhostButton("All Displays", symbol: "rectangle.on.rectangle") { model.applyToAll(asset) }
                        GhostButton("Preview", symbol: "play.fill") { model.previewAsset = asset }
                    } else {
                        PrimaryButton("Import your first wallpaper", symbol: "plus", action: model.chooseVideos)
                    }
                }
            }
            .padding(.horizontal, 36)
            .padding(.bottom, 36)
            .frame(maxWidth: 760, alignment: .leading)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 420)
    }

    private var statusLabel: String {
        guard let asset else { return "FEATURED" }
        return model.isActive(asset) ? "NOW PLAYING" : "FEATURED FROM YOUR LIBRARY"
    }

    private func meta(_ asset: WallpaperAsset) -> String {
        "\(Int(asset.pixelSize.width)) × \(Int(asset.pixelSize.height))  ·  \(Int(asset.framesPerSecond)) FPS  ·  \(asset.category.title)"
    }
}

// MARK: - Library

private struct LibraryPage: View {
    @Bindable var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                PageHeader(title: "Library", subtitle: "Playlists, schedules, and saved videos") {
                    PrimaryButton("Import", symbol: "plus", action: model.chooseVideos)
                }

                playlistSection
                dayNightSection
                appearanceSection
                savedSection
            }
            .padding(28)
        }
    }

    private var playlistSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Wallpaper Playlists")
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                    Text("Rotate chosen videos on a timer.")
                        .foregroundStyle(Theme.textDim)
                }
                Spacer()
                if model.activePlaylistID != nil {
                    GhostButton("Stop rotation", symbol: "stop.fill") {
                        model.stopPlaylistRotation()
                    }
                }
            }

            Button { model.beginPlaylistEditor() } label: {
                    ZStack {
                        if let url = model.featured?.posterURL, let poster = NSImage(contentsOf: url) {
                            Image(nsImage: poster)
                                .resizable()
                                .scaledToFill()
                                .opacity(0.35)
                        } else {
                            Theme.panel
                        }
                        Color.black.opacity(0.35)
                        Text("+ Create Playlist")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 18)
                            .frame(height: 36)
                            .background(.white, in: Capsule())
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 120)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(style: StrokeStyle(lineWidth: 1.2, dash: [7, 5]))
                            .foregroundStyle(Theme.line)
                    )
                }
                .buttonStyle(.plain)
                .disabled(model.assets.isEmpty)

            if !model.playlists.isEmpty {
                ForEach(model.playlists) { playlist in
                    let isActive = model.activePlaylistID == playlist.id
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 8) {
                                Text(playlist.name).font(.subheadline.weight(.semibold))
                                if isActive {
                                    Text("ACTIVE")
                                        .font(.system(size: 9, weight: .bold))
                                        .padding(.horizontal, 7)
                                        .frame(height: 18)
                                        .background(Theme.accent.opacity(0.92), in: Capsule())
                                        .foregroundStyle(.black)
                                }
                            }
                            Text("\(playlist.wallpaperIDs.count) items · \(playlist.shuffled ? "Shuffled" : "Ordered") · every \(playlist.intervalMinutes)m")
                                .font(.caption)
                                .foregroundStyle(Theme.textDim)
                        }
                        Spacer()
                        if isActive {
                            GhostButton("Stop", symbol: nil) { model.stopPlaylistRotation() }
                        } else {
                            PrimaryButton("Apply", symbol: nil) { model.applyPlaylist(playlist) }
                        }
                        GhostButton("Edit", symbol: nil) { model.beginPlaylistEditor(existing: playlist) }
                        Button("Delete", role: .destructive) { model.deletePlaylist(playlist) }
                            .buttonStyle(.plain)
                    }
                    .padding(12)
                    .background(
                        isActive ? Theme.accent.opacity(0.10) : Theme.panel,
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .stroke(isActive ? Theme.accent.opacity(0.45) : Theme.line)
                    )
                }
            }
        }
    }

    private var dayNightSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            automationHeader(
                title: "Day/Night Time Wallpaper",
                subtitle: "Automatically switch between two wallpapers based on time of day.",
                enabled: model.automations.dayNightEnabled,
                expanded: model.dayNightExpanded,
                onEnable: { model.setDayNightEnabled($0) },
                onToggleExpand: { model.dayNightExpanded.toggle() }
            )

            if model.dayNightExpanded {
                HStack(spacing: 14) {
                    AutomationSlotCard(
                        symbol: "sun.max.fill",
                        title: "Day",
                        detail: "Choose wallpaper",
                        footnote: "From 6:00 AM",
                        asset: model.asset(for: model.automations.dayWallpaperID)
                    ) {
                        model.automationPickSlot = .day
                    }
                    AutomationSlotCard(
                        symbol: "moon.fill",
                        title: "Night",
                        detail: "Choose wallpaper",
                        footnote: "From 6:00 PM",
                        asset: model.asset(for: model.automations.nightWallpaperID)
                    ) {
                        model.automationPickSlot = .night
                    }
                }
            }
        }
    }

    private var appearanceSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            automationHeader(
                title: "Light/Dark Mode Wallpaper",
                subtitle: "Automatically switch between two wallpapers based on system light or dark mode.",
                enabled: model.automations.appearanceEnabled,
                expanded: model.appearanceExpanded,
                onEnable: { model.setAppearanceEnabled($0) },
                onToggleExpand: { model.appearanceExpanded.toggle() }
            )

            if model.appearanceExpanded {
                HStack(spacing: 14) {
                    AutomationSlotCard(
                        symbol: "sun.max.fill",
                        title: "Light",
                        detail: "Choose wallpaper",
                        footnote: "Light mode",
                        asset: model.asset(for: model.automations.lightWallpaperID)
                    ) {
                        model.automationPickSlot = .light
                    }
                    AutomationSlotCard(
                        symbol: "moon.fill",
                        title: "Dark",
                        detail: "Choose wallpaper",
                        footnote: "Dark mode",
                        asset: model.asset(for: model.automations.darkWallpaperID)
                    ) {
                        model.automationPickSlot = .dark
                    }
                }
            }
        }
    }

    private var savedSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Saved Wallpapers")
                .font(.system(size: 20, weight: .bold, design: .rounded))
            Text(
                model.filteredAssets.isEmpty && !model.searchText.isEmpty
                    ? "No wallpapers match this search."
                    : (model.assets.isEmpty
                        ? "Import a video to start your collection."
                        : "Your collection of \(model.assets.count) saved wallpaper\(model.assets.count == 1 ? "" : "s").")
            )
            .foregroundStyle(Theme.textDim)

            if model.assets.isEmpty {
                EmptyInvite(action: model.chooseVideos)
            } else {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 220, maximum: 300), spacing: 16)],
                    spacing: 16
                ) {
                    ForEach(model.filteredAssets) { asset in
                        SavedWallpaperTile(model: model, asset: asset)
                    }
                }
            }
        }
    }

    private func automationHeader(
        title: String,
        subtitle: String,
        enabled: Bool,
        expanded: Bool,
        onEnable: @escaping (Bool) -> Void,
        onToggleExpand: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(Theme.textDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            HStack(spacing: 10) {
                Text("Enable")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.textDim)
                Toggle(
                    "",
                    isOn: Binding(
                        get: { enabled },
                        set: { newValue in onEnable(newValue) }
                    )
                )
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                Button(action: onToggleExpand) {
                    Image(systemName: "chevron.down")
                        .rotationEffect(.degrees(expanded ? 0 : -90))
                        .frame(width: 28, height: 28)
                        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

private struct AutomationSlotCard: View {
    let symbol: String
    let title: String
    let detail: String
    let footnote: String
    let asset: WallpaperAsset?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                if let url = asset?.posterURL, let image = NSImage(contentsOf: url) {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    Theme.panelStrong
                }
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
            .frame(height: 168)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Theme.line)
            )
        }
        .buttonStyle(.plain)
    }
}

private struct SavedWallpaperTile: View {
    @Bindable var model: AppModel
    let asset: WallpaperAsset

    var body: some View {
        ZStack(alignment: .topLeading) {
            Group {
                if let url = asset.posterURL, let image = NSImage(contentsOf: url) {
                    Image(nsImage: image).resizable().scaledToFill()
                } else {
                    Theme.panel
                }
            }
            .frame(maxWidth: .infinity)
            .aspectRatio(16 / 10, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

            if let display = model.displaysUsing(asset).first {
                Text("• \(display.name)")
                    .font(.system(size: 10, weight: .semibold))
                    .padding(.horizontal, 9)
                    .frame(height: 22)
                    .background(Color(red: 0.22, green: 0.48, blue: 0.98).opacity(0.95), in: Capsule())
                    .foregroundStyle(.white)
                    .padding(10)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Theme.line)
        )
        .onTapGesture { model.previewAsset = asset }
        .contextMenu {
            Button("Use on Main Display") { model.apply(asset) }
            Button("Use on All Displays") { model.applyToAll(asset) }
            Menu("Category") {
                ForEach(WallpaperCategory.allCases) { category in
                    Button(category.title) { model.setCategory(category, for: asset) }
                }
            }
            Button("Remove", role: .destructive) { model.remove(asset) }
        }
    }
}

private struct AutomationPickSheet: View {
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
        }
    }
}

// MARK: - Displays / Playlists / Settings

private struct DisplaysPage: View {
    @Bindable var model: AppModel
    private var bounds: CGRect {
        model.displays.map(\.frame).reduce(.null) { $0.union($1) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text("Displays")
                    .font(.system(size: 32, weight: .bold, design: .rounded))
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

private struct DisplayMapTile: View {
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
                        if let url = asset?.posterURL, let image = NSImage(contentsOf: url) {
                            Image(nsImage: image).resizable().scaledToFill()
                        } else {
                            Rectangle().fill(.white.opacity(0.06))
                        }
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

private struct DisplayCard: View {
    @Bindable var model: AppModel
    let display: ConnectedDisplay

    var body: some View {
        let asset = model.asset(for: model.activeByDisplay[display.displayID])
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Group {
                    if let url = asset?.posterURL, let image = NSImage(contentsOf: url) {
                        Image(nsImage: image).resizable().scaledToFill()
                    } else {
                        Theme.panelStrong
                    }
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
    }
}

private struct SettingsPage: View {
    @Bindable var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Settings")
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                    Text("Energy, lock, and local storage.")
                        .foregroundStyle(Theme.textDim)
                }

                settingsGroup(title: "Playback & energy", symbol: "leaf.fill") {
                    VStack(spacing: 0) {
                        ForEach(PowerProfile.allCases, id: \.self) { profile in
                            Button { model.setPowerProfile(profile) } label: {
                                HStack(spacing: 14) {
                                    Image(systemName: profile.symbol)
                                        .frame(width: 28, height: 28)
                                        .foregroundStyle(model.powerProfile == profile ? Theme.accent : .secondary)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(profile.label).fontWeight(.semibold)
                                        Text(profile.detail)
                                            .font(.system(size: 11))
                                            .foregroundStyle(Theme.textDim)
                                    }
                                    Spacer()
                                    Image(systemName: model.powerProfile == profile ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(model.powerProfile == profile ? Theme.accent : Color.white.opacity(0.22))
                                }
                                .contentShape(Rectangle())
                                .padding(.vertical, 11)
                            }
                            .buttonStyle(.plain)
                            if profile != PowerProfile.allCases.last {
                                Divider().overlay(Theme.line)
                            }
                        }
                        Divider().overlay(Theme.line)
                        settingsRow(
                            title: "Pause when the desktop is hidden",
                            detail: "Stops that screen when a window covers about 92% of it.",
                            symbol: "rectangle.slash"
                        ) {
                            Toggle("", isOn: Binding(
                                get: { model.pauseWhenObscured },
                                set: { model.setPauseWhenObscured($0) }
                            ))
                            .labelsHidden()
                        }
                        Divider().overlay(Theme.line)
                        settingsRow(
                            title: "Pause when the Mac is locked",
                            detail: "Stops live video behind the lock screen. The still poster stays.",
                            symbol: "lock.fill"
                        ) {
                            Toggle("", isOn: Binding(
                                get: { model.pauseOnLock },
                                set: { model.setPauseOnLock($0) }
                            ))
                            .labelsHidden()
                        }
                        Divider().overlay(Theme.line)
                        settingsRow(
                            title: "Still desktop only",
                            detail: "Hides the live overlay. System Settings still has the poster. Video cannot play on the lock screen without a wallpaper extension.",
                            symbol: "photo"
                        ) {
                            Toggle("", isOn: Binding(
                                get: { model.hideDesktopVideo },
                                set: { model.setHideDesktopVideo($0) }
                            ))
                            .labelsHidden()
                        }
                    }
                }

                settingsGroup(title: "App", symbol: "app.badge") {
                    settingsRow(
                        title: "Launch at login",
                        detail: "Starts LumaWall in the background after you sign in.",
                        symbol: "power"
                    ) {
                        Toggle(
                            "",
                            isOn: Binding(
                                get: { model.launchAtLogin },
                                set: { model.setLaunchAtLogin($0) }
                            )
                        )
                        .labelsHidden()
                    }
                }

                settingsGroup(title: "Storage", symbol: "internaldrive.fill") {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(spacing: 12) {
                            StatPill(title: "Process RAM", value: String(format: "%.0f MB", model.processMemoryMB))
                            StatPill(title: "Library on disk", value: String(format: "%.0f MB", model.libraryDiskMB))
                            StatPill(title: "Wallpapers", value: "\(model.assets.count)")
                            Spacer()
                        }
                        Divider().overlay(Theme.line)
                        HStack(spacing: 10) {
                            GhostButton("Clear RAM cache", symbol: "memorychip") { model.clearMemoryCache() }
                            GhostButton("Clear disk cache", symbol: "externaldrive") { model.clearDiskCache() }
                        }
                        Text("Clearing cache keeps your imported videos. It only drops temporary files.")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textDim)
                    }
                }

                settingsGroup(title: "Status", symbol: "info.circle") {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                        statusCell(title: "Playback", value: model.playbackStopped ? "Paused" : (model.activeByDisplay.isEmpty ? "Idle" : "Live"))
                        statusCell(title: "Displays", value: "\(model.activeByDisplay.count) of \(model.displays.count) live")
                        statusCell(title: "Energy", value: model.powerProfile.label)
                        statusCell(title: "Automations", value: automationStatus)
                        statusCell(title: "App CPU", value: String(format: "%.1f%%", model.processCPUPercent))
                        statusCell(title: "System CPU", value: String(format: "%.1f%%", model.systemCPUPercent))
                        statusCell(title: "Battery", value: model.isOnBattery ? "\(model.batteryPercent)% battery" : "Power adapter")
                        statusCell(title: "RAM", value: String(format: "%.0f MB", model.processMemoryMB))
                    }
                }

                HStack(spacing: 14) {
                    BrandMark(size: 52)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("LumaWall").font(.headline)
                        Text("Local video wallpapers. No account. No tracking.")
                            .font(.caption).foregroundStyle(Theme.textDim)
                        Text("v0.3.5").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.panel, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(Theme.line))
            }
            .padding(28)
        }
        .onAppear { model.refreshStats() }
    }

    private var automationStatus: String {
        if model.automations.dayNightEnabled { return "Day/Night" }
        if model.automations.appearanceEnabled { return "Light/Dark" }
        if model.activePlaylistID != nil { return "Playlist" }
        return "Off"
    }

    private func settingsGroup<Content: View>(
        title: String,
        symbol: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: symbol)
                .font(.headline)
            content()
                .padding(16)
                .background(Theme.panel, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 18).stroke(Theme.line))
        }
    }

    private func settingsRow<Trailing: View>(
        title: String,
        detail: String,
        symbol: String,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .frame(width: 28, height: 28)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).fontWeight(.semibold)
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textDim)
            }
            Spacer()
            trailing()
        }
        .padding(.vertical, 4)
    }

    private func statusCell(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.textDim)
            Text(value)
                .font(.system(size: 16, weight: .semibold, design: .rounded))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Theme.panelStrong, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

}

private struct StatPill: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(Theme.textDim)
            Text(value).font(.system(size: 16, weight: .semibold, design: .rounded))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Theme.panelStrong, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

// MARK: - Shared UI

private enum TileStyle {
    case cinematic
    case gallery
}

private struct WallpaperTile: View {
    @Bindable var model: AppModel
    let asset: WallpaperAsset
    var width: CGFloat? = nil
    var style: TileStyle = .gallery
    var showCategory: Bool = false
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack {
                poster
                    .aspectRatio(16 / 10, contentMode: .fill)
                    .clipped()

                if hovering {
                    LoopingVideoView(url: asset.mediaURL)
                        .aspectRatio(16 / 10, contentMode: .fill)
                        .clipped()
                        .transition(.opacity)
                    Color.black.opacity(0.28)
                    HStack(spacing: 8) {
                        PrimaryButton("Use", symbol: "display") { model.apply(asset) }
                        GhostButton("Preview", symbol: "play.fill") { model.previewAsset = asset }
                    }
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
                }

                VStack {
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
                    }
                    Spacer()
                }
                .padding(10)
            }
            .clipShape(RoundedRectangle(cornerRadius: style == .cinematic ? 18 : 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: style == .cinematic ? 18 : 16, style: .continuous)
                    .stroke(hovering ? Theme.accent.opacity(0.45) : Theme.line, lineWidth: 1)
            )
            .shadow(color: .black.opacity(hovering ? 0.35 : 0.18), radius: hovering ? 16 : 8, y: hovering ? 8 : 4)
            .scaleEffect(hovering ? 1.015 : 1)
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
    }

    @ViewBuilder private var poster: some View {
        if let url = asset.posterURL, let image = NSImage(contentsOf: url) {
            Image(nsImage: image).resizable().scaledToFill()
        } else {
            Rectangle().fill(.white.opacity(0.06))
        }
    }
}

private struct LibraryCard: View {
    @Bindable var model: AppModel
    let asset: WallpaperAsset
    @State private var draftName: String = ""
    @State private var isEditingName = false
    @FocusState private var nameFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            WallpaperTile(model: model, asset: asset, style: .gallery, showCategory: true)

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

private struct AssignSheet: View {
    @Bindable var model: AppModel
    let display: ConnectedDisplay
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                BrandMark(size: 28)
                Text("Assign to \(display.name)").font(.title2.bold())
            }
            if model.assets.isEmpty {
                Text("Import a wallpaper first.").foregroundStyle(Theme.textDim)
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
                                Image(systemName: "checkmark").foregroundStyle(Theme.accent)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            Button("Close", action: dismiss.callAsFunction)
        }
        .padding(20)
        .frame(width: 440, height: 500)
    }
}

private struct PreviewSheet: View {
    @Bindable var model: AppModel
    let asset: WallpaperAsset
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            LoopingVideoView(url: asset.mediaURL)
                .aspectRatio(16 / 9, contentMode: .fit)
                .background(.black)
            HStack(spacing: 12) {
                BrandMark(size: 28)
                VStack(alignment: .leading, spacing: 4) {
                    Text(asset.name).font(.title3.bold())
                    Text("\(Int(asset.pixelSize.width))×\(Int(asset.pixelSize.height)) · \(Int(asset.framesPerSecond)) FPS")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Picker("Category", selection: Binding(
                    get: { asset.category },
                    set: { model.setCategory($0, for: asset) }
                )) {
                    ForEach(WallpaperCategory.allCases) { category in
                        Text(category.title).tag(category)
                    }
                }
                .labelsHidden()
                .frame(width: 140)
                Button {
                    model.toggleFavorite(asset)
                } label: {
                    Image(systemName: model.isFavorite(asset) ? "heart.fill" : "heart")
                        .foregroundStyle(model.isFavorite(asset) ? .pink : .primary)
                        .frame(width: 34, height: 34)
                        .background(.white.opacity(0.08), in: Circle())
                }
                .buttonStyle(.plain)
                PrimaryButton("Use Wallpaper", symbol: "display") {
                    model.apply(asset)
                    dismiss()
                }
                Button("Done", action: dismiss.callAsFunction).keyboardShortcut(.cancelAction)
            }
            .padding(16)
        }
        .frame(width: 920, height: 600)
    }
}

private struct MenuBarRoot: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                BrandMark(size: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text("LumaWall").font(.headline)
                    Text(statusLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                Button(model.isPaused ? "Resume" : "Pause", action: model.togglePause)
                Button("Reapply") { model.reapplyActive() }
                    .disabled(model.featured == nil)
            }

            if model.activePlaylistID != nil {
                HStack {
                    Button("Previous") { model.stepPlaylist(-1) }
                    Button("Next") { model.stepPlaylist(1) }
                }
            }

            if model.recentAssets.isEmpty {
                Text("No recent wallpapers").foregroundStyle(.secondary)
            } else {
                Text("Recents").font(.caption).foregroundStyle(.secondary)
                ForEach(model.recentAssets.prefix(5)) { asset in
                    HStack(spacing: 8) {
                        poster(asset)
                        Text(asset.name).lineLimit(1)
                        Spacer()
                        Button("Apply") { model.apply(asset) }
                    }
                }
            }

            Divider()
            Button("Clear memory cache") { model.clearMemoryCache() }
            Button("Open LumaWall") {
                model.section = .home
                NSApp.setActivationPolicy(.regular)
                NSApp.activate(ignoringOtherApps: true)
                for window in NSApp.windows where window.canBecomeKey || window.isMiniaturized {
                    window.makeKeyAndOrderFront(nil)
                }
            }
            Button("Import…", action: model.chooseVideos)
        }
        .padding(14)
        .frame(width: 300)
        .onAppear { model.refreshStats() }
    }

    private var statusLine: String {
        let cpu = String(format: "%.0f", model.processCPUPercent)
        let ram = String(format: "%.0f", model.processMemoryMB)
        if model.playbackStopped { return "Paused · \(cpu)% CPU · \(ram) MB" }
        if model.activeByDisplay.isEmpty { return "Idle · \(cpu)% CPU · \(ram) MB" }
        return "Live · \(cpu)% CPU · \(ram) MB"
    }

    @ViewBuilder
    private func poster(_ asset: WallpaperAsset) -> some View {
        if let url = asset.posterURL, let image = NSImage(contentsOf: url) {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 40, height: 24)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        } else {
            RoundedRectangle(cornerRadius: 4)
                .fill(.white.opacity(0.08))
                .frame(width: 40, height: 24)
        }
    }
}

private struct PlaylistEditorSheet: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(model.playlistEditor?.existingID == nil ? "New playlist" : "Edit playlist")
                .font(.title2.bold())
            TextField("Name", text: nameBinding)
                .textFieldStyle(.roundedBorder)
            HStack {
                Text("Interval (minutes)")
                TextField("30", value: intervalBinding, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 72)
                Toggle("Shuffle", isOn: shuffleBinding)
            }
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Library").font(.headline)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(model.assets) { asset in
                                Button { model.toggleEditorEntry(asset) } label: {
                                    HStack {
                                        Text(asset.name).lineLimit(1)
                                        Spacer()
                                        if model.playlistEditor?.orderedIDs.contains(asset.id) == true {
                                            Image(systemName: "checkmark")
                                        }
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("Order").font(.headline)
                    let ids = model.playlistEditor?.orderedIDs ?? []
                    ForEach(Array(ids.enumerated()), id: \.element.rawValue) { index, id in
                        if let asset = model.asset(for: id) {
                            HStack {
                                Text(asset.name).lineLimit(1)
                                Spacer()
                                Button("Up") { model.moveEditorEntry(from: index, to: max(0, index - 1)) }
                                    .disabled(index == 0)
                                Button("Down") { model.moveEditorEntry(from: index, to: index + 1) }
                                    .disabled(index == ids.count - 1)
                            }
                        }
                    }
                }
            }
            .frame(maxHeight: .infinity)
            HStack {
                Spacer()
                Button("Cancel") {
                    model.playlistEditor = nil
                    dismiss()
                }
                Button("Save") {
                    model.savePlaylistEditor()
                    dismiss()
                }
                .disabled(model.playlistEditor?.orderedIDs.isEmpty ?? true)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 640, height: 520)
    }

    private var nameBinding: Binding<String> {
        Binding(
            get: { model.playlistEditor?.name ?? "" },
            set: { model.playlistEditor?.name = $0 }
        )
    }

    private var intervalBinding: Binding<Int> {
        Binding(
            get: { model.playlistEditor?.intervalMinutes ?? 30 },
            set: { model.playlistEditor?.intervalMinutes = $0 }
        )
    }

    private var shuffleBinding: Binding<Bool> {
        Binding(
            get: { model.playlistEditor?.shuffled ?? false },
            set: { model.playlistEditor?.shuffled = $0 }
        )
    }
}

private struct PrimaryButton: View {
    let title: String
    var symbol: String? = nil
    let action: () -> Void

    init(_ title: String, symbol: String? = nil, action: @escaping () -> Void) {
        self.title = title
        self.symbol = symbol
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let symbol { Image(systemName: symbol) }
                Text(title).fontWeight(.semibold)
            }
            .padding(.horizontal, 14)
            .frame(height: 34)
            .background(Theme.accent, in: Capsule())
            .foregroundStyle(.black)
        }
        .buttonStyle(.plain)
    }
}

private struct GhostButton: View {
    let title: String
    var symbol: String? = nil
    let action: () -> Void

    init(_ title: String, symbol: String? = nil, action: @escaping () -> Void) {
        self.title = title
        self.symbol = symbol
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let symbol { Image(systemName: symbol) }
                Text(title).fontWeight(.medium)
            }
            .padding(.horizontal, 14)
            .frame(height: 34)
            .background(.white.opacity(0.08), in: Capsule())
            .overlay(Capsule().stroke(Theme.line))
        }
        .buttonStyle(.plain)
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
                .background(selected ? Theme.accent : .white.opacity(0.06), in: Capsule())
                .foregroundStyle(selected ? .black : .white.opacity(0.72))
        }
        .buttonStyle(.plain)
    }
}

private struct QuickLink: View {
    let symbol: String, title: String, detail: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 36, height: 36)
                    .background(Theme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 13, weight: .semibold))
                    Text(detail).font(.system(size: 11)).foregroundStyle(Theme.textDim)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.line))
        }
        .buttonStyle(.plain)
    }
}

private struct EmptyInvite: View {
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                BrandMark(size: 48)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Add your first wallpaper").font(.headline)
                    Text("Drop an MP4 or MOV anywhere in this window").foregroundStyle(Theme.textDim)
                }
                Spacer()
                Text("Choose Video").fontWeight(.semibold)
            }
            .padding(18)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(style: StrokeStyle(lineWidth: 1, dash: [6])))
        }
        .buttonStyle(.plain)
    }
}

private struct BusyOverlay: View {
    let text: String
    var body: some View {
        ZStack {
            Color.black.opacity(0.42).ignoresSafeArea()
            VStack(spacing: 12) {
                BrandMark(size: 40)
                ProgressView().controlSize(.large)
                Text(text).fontWeight(.semibold)
            }
            .padding(28)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
    }
}

private struct PageHeader<Trailing: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var trailing: () -> Trailing

    init(title: String, subtitle: String, @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing
    }

    var body: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.system(size: 32, weight: .bold, design: .rounded))
                Text(subtitle).foregroundStyle(Theme.textDim)
            }
            Spacer()
            trailing()
        }
    }
}

private struct SectionHeading: View {
    let title: String
    let subtitle: String
    var action: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 20, weight: .bold, design: .rounded))
                Text(subtitle).font(.caption).foregroundStyle(Theme.textDim)
            }
            Spacer()
            if let action {
                Button("See all", systemImage: "chevron.right", action: action)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
        }
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

    var symbol: String {
        switch self {
        case .automatic: "leaf.fill"
        case .fullQuality: "bolt.fill"
        case .batterySaver: "battery.50"
        case .staticOnBattery: "pause.rectangle.fill"
        }
    }
}
