import AppKit
import LumaWallCore
import SwiftUI

@main
struct LumaWallApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup("LumaWall", id: "main") {
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
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        DispatchQueue.main.async { sender.setActivationPolicy(.accessory) }
        return false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        sender.setActivationPolicy(.regular)
        return true
    }
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
        .onAppear {
            NSApp.setActivationPolicy(.regular)
            NSApp.keyWindow?.identifier = NSUserInterfaceItemIdentifier("LumaWallMainWindow")
        }
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
    @State private var mode: LibraryMode = .wallpapers
    @State private var selectedID: WallpaperID?

    private enum LibraryMode: String, CaseIterable, Identifiable {
        case wallpapers = "Wallpapers"
        case playlists = "Playlists"
        case automations = "Automations"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            PageHeader(title: "Library", subtitle: "Organize, inspect, and apply your local wallpapers") {
                HStack(spacing: 10) {
                    Picker("Library section", selection: $mode) {
                        ForEach(LibraryMode.allCases) { item in Text(item.rawValue).tag(item) }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 330)
                    PrimaryButton("Import", symbol: "plus", action: model.chooseVideos)
                }
            }

            switch mode {
            case .wallpapers:
                wallpaperWorkspace
            case .playlists:
                ScrollView { playlistSection.padding(.bottom, 28) }
            case .automations:
                ScrollView {
                    VStack(alignment: .leading, spacing: 28) {
                        dayNightSection
                        appearanceSection
                    }
                    .padding(.bottom, 28)
                }
            }
        }
        .padding(.horizontal, 28)
        .padding(.top, 28)
        .onAppear { validateSelection() }
        .onChange(of: model.filteredAssets.map(\.id)) { _, _ in validateSelection() }
    }

    private var wallpaperWorkspace: some View {
        VStack(alignment: .leading, spacing: 14) {
            libraryToolbar
            if model.assets.isEmpty {
                EmptyInvite(action: model.chooseVideos)
                    .frame(maxHeight: .infinity)
            } else if model.filteredAssets.isEmpty {
                ContentUnavailableView(
                    "No Matching Wallpapers",
                    systemImage: "rectangle.stack.badge.minus",
                    description: Text("Clear a filter or try a different search.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HSplitView {
                    ScrollView {
                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: 190, maximum: 260), spacing: 14)],
                            spacing: 16
                        ) {
                            ForEach(model.filteredAssets) { asset in
                                LibrarySelectionTile(
                                    model: model,
                                    asset: asset,
                                    isSelected: selectedID == asset.id
                                ) { selectedID = asset.id }
                            }
                        }
                        .padding(.vertical, 2)
                        .padding(.trailing, 12)
                    }
                    .frame(minWidth: 430)

                    LibraryInspector(model: model, asset: selectedAsset)
                        .frame(minWidth: 280, idealWidth: 320, maxWidth: 380)
                }
            }
        }
    }

    private var selectedAsset: WallpaperAsset? {
        guard let selectedID else { return nil }
        return model.assets.first { $0.id == selectedID }
    }

    private var libraryToolbar: some View {
        HStack(spacing: 10) {
            TextField("Search your library", text: $model.searchText)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 180, maxWidth: 320)
            Picker("Resolution", selection: $model.resolutionFilter) {
                ForEach(ResolutionFilter.allCases) { Text($0.title).tag($0) }
            }
            .frame(width: 130)
            Picker("Category", selection: $model.categoryFilter) {
                Text("All categories").tag(Optional<WallpaperCategory>.none)
                ForEach(WallpaperCategory.allCases) { Text($0.title).tag(Optional($0)) }
            }
            .frame(width: 150)
            Picker("Sort", selection: Binding(
                get: { model.librarySort },
                set: { model.setSort($0) }
            )) {
                ForEach(LibrarySort.allCases) { Text($0.title).tag($0) }
            }
            .frame(width: 125)
            Toggle(isOn: $model.favoritesOnly) {
                Label("Favorites", systemImage: "heart.fill")
            }
            .toggleStyle(.button)
            Spacer(minLength: 8)
            Text("\(model.filteredAssets.count) of \(model.assets.count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(Theme.textDim)
        }
        .controlSize(.small)
    }

    private func validateSelection() {
        if let selectedID, model.filteredAssets.contains(where: { $0.id == selectedID }) { return }
        selectedID = model.filteredAssets.first?.id
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
                        footnote: "From \(formattedHour(model.automations.dayStartHour))",
                        asset: model.asset(for: model.automations.dayWallpaperID)
                    ) {
                        model.automationPickSlot = .day
                    }
                    AutomationSlotCard(
                        symbol: "moon.fill",
                        title: "Night",
                        detail: "Choose wallpaper",
                        footnote: "From \(formattedHour(model.automations.nightStartHour))",
                        asset: model.asset(for: model.automations.nightWallpaperID)
                    ) {
                        model.automationPickSlot = .night
                    }
                }
                HStack(spacing: 14) {
                    schedulePicker(
                        "Day begins",
                        selection: Binding(
                            get: { model.automations.dayStartHour },
                            set: { model.setDayStartHour($0) }
                        )
                    )
                    schedulePicker(
                        "Night begins",
                        selection: Binding(
                            get: { model.automations.nightStartHour },
                            set: { model.setNightStartHour($0) }
                        )
                    )
                }
            }
        }
    }

    private func schedulePicker(_ title: String, selection: Binding<Int>) -> some View {
        HStack {
            Text(title).font(.system(size: 12, weight: .semibold))
            Spacer()
            Picker(title, selection: selection) {
                ForEach(0..<24, id: \.self) { hour in
                    Text(formattedHour(hour)).tag(hour)
                }
            }
            .labelsHidden()
            .frame(width: 120)
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.line))
    }

    private func formattedHour(_ hour: Int) -> String {
        let date = Calendar.current.date(from: DateComponents(hour: hour)) ?? .now
        return date.formatted(date: .omitted, time: .shortened)
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

private struct LibrarySelectionTile: View {
    @Bindable var model: AppModel
    let asset: WallpaperAsset
    let isSelected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            VStack(alignment: .leading, spacing: 9) {
                ZStack(alignment: .topLeading) {
                    Group {
                        if let url = asset.posterURL, let image = NSImage(contentsOf: url) {
                            Image(nsImage: image).resizable().scaledToFill()
                        } else {
                            Theme.panelStrong
                        }
                    }
                    .aspectRatio(16 / 10, contentMode: .fill)
                    .clipped()

                    HStack(spacing: 6) {
                        if model.isActive(asset) {
                            Text("IN USE")
                                .foregroundStyle(.black)
                                .background(Theme.accent, in: Capsule())
                        }
                        if model.isFavorite(asset) {
                            Image(systemName: "heart.fill")
                                .foregroundStyle(.pink)
                                .background(.black.opacity(0.55), in: Circle())
                        }
                    }
                    .font(.system(size: 9, weight: .bold))
                    .padding(9)
                }
                .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))

                Text(asset.name)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Text("\(asset.resolutionLabel) · \(Int(asset.framesPerSecond)) FPS · \(asset.category.title)")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textDim)
                    .lineLimit(1)
            }
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

private struct LibraryInspector: View {
    @Bindable var model: AppModel
    let asset: WallpaperAsset?
    @State private var draftName = ""

    var body: some View {
        Group {
            if let asset {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        poster(asset)
                        TextField("Wallpaper name", text: $draftName)
                            .font(.title3.weight(.semibold))
                            .textFieldStyle(.plain)
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
                            Label("Use as Wallpaper", systemImage: "display")
                                .frame(maxWidth: .infinity)
                        }
                        .menuStyle(.borderlessButton)
                        .padding(.vertical, 9)
                        .background(Theme.accent, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                        .foregroundStyle(.black)

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
                    .padding(18)
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
    }

    private func poster(_ asset: WallpaperAsset) -> some View {
        Group {
            if let url = asset.posterURL, let image = NSImage(contentsOf: url) {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                Theme.panelStrong
            }
        }
        .aspectRatio(16 / 10, contentMode: .fill)
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

                settingsGroup(title: "Wallpaper host", symbol: "rectangle.on.rectangle.angled") {
                    settingsRow(
                        title: model.wallpaperHostMode == .native ? "System wallpaper (macOS 26)" : "Desktop overlay",
                        detail: model.wallpaperHostMode == .native
                            ? "Uses WallpaperExtensionKit through the LumaWall wallpaper extension."
                            : "Uses the poster plus live overlay. Native host needs macOS 26 and an app build that embeds the wallpaper extension.",
                        symbol: model.wallpaperHostMode == .native ? "checkmark.seal.fill" : "square.stack.3d.up"
                    ) {
                        EmptyView()
                    }
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
                            detail: model.wallpaperHostMode == .native
                                ? "Asks the wallpaper extension to keep the desktop still while the system host stays assigned."
                                : "Hides the live overlay. System Settings still has the poster.",
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

private struct AssignSheet: View {
    @Bindable var model: AppModel
    let display: ConnectedDisplay
    @Environment(\.dismiss) private var dismiss
    @State private var selectedID: WallpaperID?
    @State private var composition = DisplayComposition()

    private var selectedAsset: WallpaperAsset? {
        guard let selectedID else { return nil }
        return model.assets.first { $0.id == selectedID }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                BrandMark(size: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Compose for \(display.name)").font(.title2.bold())
                    Text("\(Int(display.pixelSize.width))×\(Int(display.pixelSize.height))")
                        .font(.caption).foregroundStyle(Theme.textDim)
                }
            }
            if model.assets.isEmpty {
                Text("Import a wallpaper first.").foregroundStyle(Theme.textDim)
            } else {
                ZStack {
                    Rectangle().fill(.black)
                    if let url = selectedAsset?.posterURL, let image = NSImage(contentsOf: url) {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: contentMode)
                            .scaleEffect(composition.scale)
                            .rotationEffect(.degrees(composition.rotationDegrees))
                            .offset(x: composition.offset.x * 0.18, y: -composition.offset.y * 0.18)
                    }
                }
                .frame(maxWidth: .infinity)
                .aspectRatio(max(display.frame.width / max(display.frame.height, 1), 1), contentMode: .fit)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(Theme.line))

                Picker("Wallpaper", selection: $selectedID) {
                    ForEach(model.assets) { asset in Text(asset.name).tag(Optional(asset.id)) }
                }

                HStack {
                    Picker("Sizing", selection: $composition.contentMode) {
                        Text("Fill").tag(LumaWallCore.ContentMode.fill)
                        Text("Fit").tag(LumaWallCore.ContentMode.fit)
                        Text("Stretch").tag(LumaWallCore.ContentMode.stretch)
                    }
                    .pickerStyle(.segmented)
                    Button("Reset") { composition = .init() }.buttonStyle(.borderless)
                }

                compositionSlider("Scale", value: $composition.scale, range: 0.5...2, format: "%.2f×")
                compositionSlider("Rotation", value: $composition.rotationDegrees, range: -180...180, format: "%.0f°")
                compositionSlider("Horizontal", value: xOffset, range: -600...600, format: "%.0f")
                compositionSlider("Vertical", value: yOffset, range: -600...600, format: "%.0f")

                HStack(spacing: 10) {
                    Text("Focal point")
                    Slider(value: focalX, in: 0...1)
                    Slider(value: focalY, in: 0...1)
                }
                .font(.system(size: 12, weight: .medium))
            }
            HStack {
                Button("Cancel", action: dismiss.callAsFunction).keyboardShortcut(.cancelAction)
                Spacer()
                Button("Apply to Display") {
                    guard let selectedAsset else { return }
                    model.apply(selectedAsset, to: display.displayID, composition: composition)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedAsset == nil)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 620, height: 720)
        .onAppear {
            selectedID = model.activeByDisplay[display.displayID] ?? model.assets.first?.id
            composition = model.composition(on: display)
        }
    }

    private var contentMode: SwiftUI.ContentMode {
        switch composition.contentMode {
        case .fill: .fill
        case .fit: .fit
        case .stretch: .fill
        }
    }

    private var xOffset: Binding<Double> {
        Binding(get: { Double(composition.offset.x) }, set: { composition.offset.x = CGFloat($0) })
    }

    private var yOffset: Binding<Double> {
        Binding(get: { Double(composition.offset.y) }, set: { composition.offset.y = CGFloat($0) })
    }

    private var focalX: Binding<Double> {
        Binding(get: { Double(composition.focalPoint.x) }, set: { composition.focalPoint.x = CGFloat($0) })
    }

    private var focalY: Binding<Double> {
        Binding(get: { Double(composition.focalPoint.y) }, set: { composition.focalPoint.y = CGFloat($0) })
    }

    private func compositionSlider(
        _ title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        format: String
    ) -> some View {
        HStack(spacing: 12) {
            Text(title).frame(width: 72, alignment: .leading)
            Slider(value: value, in: range)
            Text(String(format: format, value.wrappedValue))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(Theme.textDim)
                .frame(width: 54, alignment: .trailing)
        }
        .font(.system(size: 12, weight: .medium))
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
    @Environment(\.openWindow) private var openWindow

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

            HStack(spacing: 8) {
                Button(model.isPaused ? "Resume All" : "Pause All", action: model.togglePause)
                    .buttonStyle(.borderedProminent)
                Button("Reapply") { model.reapplyActive() }
                    .disabled(model.featured == nil)
            }

            if !model.displays.isEmpty {
                Divider()
                Text("Displays").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(model.displays) { display in
                    HStack(spacing: 8) {
                        Image(systemName: display.isMain ? "display" : "rectangle.connected.to.line.below")
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(display.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                            Text(model.activeName(on: display) ?? "Not assigned")
                                .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        if model.activeByDisplay[display.displayID] != nil {
                            Button(model.pausedDisplayIDs.contains(display.displayID) ? "Resume" : "Pause") {
                                model.togglePause(on: display)
                            }
                            .controlSize(.small)
                        }
                    }
                }
            }

            Divider()
            Picker("Power", selection: Binding(
                get: { model.powerProfile },
                set: { model.setPowerProfile($0) }
            )) {
                Text("Automatic").tag(PowerProfile.automatic)
                Text("Full Quality").tag(PowerProfile.fullQuality)
                Text("Battery Saver").tag(PowerProfile.batterySaver)
                Text("Static on Battery").tag(PowerProfile.staticOnBattery)
            }
            .pickerStyle(.menu)

            if !model.playlists.isEmpty {
                Menu {
                    ForEach(model.playlists) { playlist in
                        Button {
                            model.applyPlaylist(playlist)
                        } label: {
                            if model.activePlaylistID == playlist.id {
                                Label(playlist.name, systemImage: "checkmark")
                            } else {
                                Text(playlist.name)
                            }
                        }
                    }
                    if model.activePlaylistID != nil {
                        Divider()
                        Button("Previous") { model.stepPlaylist(-1) }
                        Button("Next") { model.stepPlaylist(1) }
                        Button("Stop Playlist", role: .destructive) { model.stopPlaylistRotation() }
                    }
                } label: {
                    Label(activePlaylistName, systemImage: "list.bullet")
                }
                .menuStyle(.borderlessButton)
            }

            Menu {
                Toggle("Day / Night", isOn: Binding(
                    get: { model.automations.dayNightEnabled },
                    set: { model.setDayNightEnabled($0) }
                ))
                Toggle("Light / Dark", isOn: Binding(
                    get: { model.automations.appearanceEnabled },
                    set: { model.setAppearanceEnabled($0) }
                ))
            } label: {
                Label(automationStatus, systemImage: "clock.arrow.trianglehead.2.counterclockwise.rotate.90")
            }
            .menuStyle(.borderlessButton)

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
                openWindow(id: "main")
                for window in NSApp.windows where window.canBecomeKey || window.isMiniaturized {
                    window.makeKeyAndOrderFront(nil)
                }
            }
            Button("Import…", action: model.chooseVideos)
            Divider()
            Button("Quit LumaWall") { NSApp.terminate(nil) }
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

    private var activePlaylistName: String {
        guard let id = model.activePlaylistID,
              let playlist = model.playlists.first(where: { $0.id == id }) else { return "Playlists" }
        return playlist.name
    }

    private var automationStatus: String {
        if model.automations.dayNightEnabled { return "Day / Night Active" }
        if model.automations.appearanceEnabled { return "Light / Dark Active" }
        return "Automations"
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
