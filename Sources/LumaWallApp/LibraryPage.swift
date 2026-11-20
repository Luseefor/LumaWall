import AppKit
import LumaWallCore
import SwiftUI

// MARK: - Library

struct LibraryPage: View {
    @Bindable var model: AppModel
    @State private var selectedID: WallpaperID?
    @State private var showsAdvancedAutomations = false

    private static let cardWidth: CGFloat = 224
    private static let cardHeight: CGFloat = 150

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                PageHeader(
                    title: "Library",
                    subtitle: "Your wallpapers, playlists, and automatic cycles"
                ) {
                    PrimaryButton("Import", symbol: "plus", action: model.chooseVideos)
                }

                playlistsShelf
                dayNightShelf
                lightDarkShelf
                allWallpapersSection
                advancedShelf
            }
            .padding(.horizontal, 32)
            .padding(.top, 28)
            .padding(.bottom, 44)
        }
        .sheet(
            item: Binding(
                get: { selectedID.map(SelectedInspector.init(assetID:)) },
                set: { selectedID = $0?.assetID }
            )
        ) { selection in
            // Look up live so library reloads while the sheet is open keep
            // working instead of pinning a stale snapshot.
            if let asset = model.assets.first(where: { $0.id == selection.assetID }) {
                LibraryInspectorSheet(model: model, asset: asset)
            }
        }
    }

    /// Identifiable wrapper giving the inspector sheet stable identity across
    /// library reloads (a derived `isPresented` boolean loses which asset is
    /// shown and drops the sheet when the asset value changes).
    private struct SelectedInspector: Identifiable {
        let assetID: WallpaperID
        var id: WallpaperID { assetID }
    }

    private var allWallpapersSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            shelfHeader(
                title: "All Wallpapers",
                subtitle: model.assets.isEmpty
                    ? "Import an MP4 or MOV to start your collection"
                    : "\(model.filteredAssets.count) of \(model.assets.count) shown",
                trailing: { EmptyView() }
            )
            libraryToolbar
            if model.assets.isEmpty {
                EmptyInvite(action: model.chooseVideos)
            } else if model.filteredAssets.isEmpty {
                ContentUnavailableView(
                    "No Matching Wallpapers",
                    systemImage: "rectangle.stack.badge.minus",
                    description: Text("Clear a filter or try a different search.")
                )
                .frame(maxWidth: .infinity, minHeight: 220)
            } else {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 210, maximum: 280), spacing: 16)],
                    spacing: 18
                ) {
                    ForEach(model.filteredAssets) { asset in
                        LibrarySelectionTile(
                            model: model,
                            asset: asset,
                            isSelected: selectedID == asset.id
                        ) { selectedID = asset.id }
                    }
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
            Picker(
                "Sort",
                selection: Binding(
                    get: { model.librarySort },
                    set: { model.setSort($0) }
                )
            ) {
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

    private func shelfHeader<Trailing: View>(
        title: String,
        subtitle: String,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 19, weight: .bold, design: .rounded))
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textDim)
            }
            Spacer(minLength: 8)
            trailing()
        }
    }

    private var playlistsShelf: some View {
        VStack(alignment: .leading, spacing: 14) {
            shelfHeader(
                title: "Playlists",
                subtitle: "Rotate through a set of wallpapers on a timer",
                trailing: {
                    if model.activePlaylistID != nil {
                        Button("Stop rotation") { model.stopPlaylistRotation() }
                            .buttonStyle(.link)
                            .font(.system(size: 12, weight: .semibold))
                    }
                }
            )
            ShelfRow {
                ShelfAddCard(
                    title: "New Playlist",
                    caption: model.assets.isEmpty ? "Import a video first" : "Pick videos and an interval",
                    width: Self.cardWidth,
                    height: Self.cardHeight
                ) { model.beginPlaylistEditor() }
                .disabled(model.assets.isEmpty)

                ForEach(model.playlists) { playlist in
                    PlaylistShelfCard(
                        model: model,
                        playlist: playlist,
                        width: Self.cardWidth,
                        height: Self.cardHeight
                    )
                }
            }
        }
    }

    private var dayNightShelf: some View {
        VStack(alignment: .leading, spacing: 14) {
            shelfHeader(
                title: "Day / Night",
                subtitle: model.automations.useSunriseSunset
                    ? "Switches at sunrise and sunset"
                    : "Switches at \(formattedHour(model.automations.dayStartHour)) and \(formattedHour(model.automations.nightStartHour))",
                trailing: {
                    Toggle(
                        "",
                        isOn: Binding(
                            get: { model.automations.dayNightEnabled },
                            set: { model.setDayNightEnabled($0) }
                        )
                    )
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .accessibilityLabel("Enable day and night cycle")
                }
            )
            ShelfRow {
                AutomationSlotCard(
                    symbol: "sun.max.fill",
                    title: "Day",
                    detail: "Choose wallpaper",
                    footnote: model.automations.useSunriseSunset
                        ? "From sunrise"
                        : "From \(formattedHour(model.automations.dayStartHour))",
                    asset: model.asset(for: model.automations.dayWallpaperID),
                    height: Self.cardHeight
                ) { model.automationPickSlot = .day }
                .frame(width: Self.cardWidth)

                AutomationSlotCard(
                    symbol: "moon.fill",
                    title: "Night",
                    detail: "Choose wallpaper",
                    footnote: model.automations.useSunriseSunset
                        ? "From sunset"
                        : "From \(formattedHour(model.automations.nightStartHour))",
                    asset: model.asset(for: model.automations.nightWallpaperID),
                    height: Self.cardHeight
                ) { model.automationPickSlot = .night }
                .frame(width: Self.cardWidth)

                scheduleCard
            }
            .opacity(model.automations.dayNightEnabled ? 1 : 0.6)
        }
    }

    private var scheduleCard: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("Schedule")
                .font(.system(size: 13, weight: .semibold))
            Toggle(
                "Sunrise / sunset",
                isOn: Binding(
                    get: { model.automations.useSunriseSunset },
                    set: { model.setUseSunriseSunset($0) }
                )
            )
            .toggleStyle(.switch)
            .controlSize(.small)
            .font(.system(size: 11))

            if model.automations.useSunriseSunset {
                Text("Needs Location When In Use so LumaWall can estimate daylight for your region.")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textDim)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                compactSchedulePicker(
                    "Day",
                    selection: Binding(
                        get: { model.automations.dayStartHour },
                        set: { model.setDayStartHour($0) }
                    )
                )
                compactSchedulePicker(
                    "Night",
                    selection: Binding(
                        get: { model.automations.nightStartHour },
                        set: { model.setNightStartHour($0) }
                    )
                )
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(width: Self.cardWidth, height: Self.cardHeight, alignment: .topLeading)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Theme.line))
    }

    private var lightDarkShelf: some View {
        VStack(alignment: .leading, spacing: 14) {
            shelfHeader(
                title: "Light / Dark",
                subtitle: "Follows the macOS system appearance",
                trailing: {
                    Toggle(
                        "",
                        isOn: Binding(
                            get: { model.automations.appearanceEnabled },
                            set: { model.setAppearanceEnabled($0) }
                        )
                    )
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .accessibilityLabel("Enable light and dark cycle")
                }
            )
            ShelfRow {
                AutomationSlotCard(
                    symbol: "sun.max.fill",
                    title: "Light",
                    detail: "Choose wallpaper",
                    footnote: "Light mode",
                    asset: model.asset(for: model.automations.lightWallpaperID),
                    height: Self.cardHeight
                ) { model.automationPickSlot = .light }
                .frame(width: Self.cardWidth)

                AutomationSlotCard(
                    symbol: "moon.fill",
                    title: "Dark",
                    detail: "Choose wallpaper",
                    footnote: "Dark mode",
                    asset: model.asset(for: model.automations.darkWallpaperID),
                    height: Self.cardHeight
                ) { model.automationPickSlot = .dark }
                .frame(width: Self.cardWidth)
            }
            .opacity(model.automations.appearanceEnabled ? 1 : 0.6)
        }
    }

    private var advancedShelf: some View {
        DisclosureGroup(isExpanded: $showsAdvancedAutomations) {
            VStack(alignment: .leading, spacing: 22) {
                automationRulesSection
                lockScreenSection
            }
            .padding(.top, 14)
        } label: {
            Text("Advanced rules and lock screen")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.textDim)
        }
    }

    private func compactSchedulePicker(_ title: String, selection: Binding<Int>) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.textDim)
            Picker(title, selection: selection) {
                ForEach(0..<24, id: \.self) { hour in
                    Text(formattedHour(hour)).tag(hour)
                }
            }
            .labelsHidden()
            .controlSize(.small)
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity)
        .frame(height: 30)
        .background(Theme.panelStrong.opacity(0.55), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.line))
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

    private var automationRulesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            automationHeader(
                title: "Rules",
                subtitle: "Limit when automations can change the desktop.",
                enabled: true,
                expanded: model.automationRulesExpanded,
                onEnable: { _ in },
                onToggleExpand: { model.automationRulesExpanded.toggle() },
                showsEnable: false
            )

            if model.automationRulesExpanded {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Active days")
                        .font(.system(size: 12, weight: .semibold))
                    HStack(spacing: 8) {
                        ForEach(Array(["S", "M", "T", "W", "T", "F", "S"].enumerated()), id: \.offset) { index, label in
                            Button {
                                model.toggleWeekday(index)
                            } label: {
                                Text(label)
                                    .font(.system(size: 12, weight: .bold))
                                    .frame(width: 32, height: 32)
                                    .background(
                                        model.isWeekdaySelected(index) ? Theme.accent.opacity(0.22) : Theme.panel,
                                        in: Circle()
                                    )
                                    .overlay(Circle().stroke(model.isWeekdaySelected(index) ? Theme.accent.opacity(0.55) : Theme.line))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(weekdayName(index))
                        }
                        if model.automations.weekdayMask != 0 {
                            Button("Every day") { model.clearWeekdayFilter() }
                                .buttonStyle(.link)
                        }
                    }

                    Divider().overlay(Theme.line)

                    Toggle(
                        "Do not interrupt",
                        isOn: Binding(
                            get: {
                                model.automations.doNotInterruptStartHour != nil
                                    && model.automations.doNotInterruptEndHour != nil
                            },
                            set: { enabled in
                                if enabled {
                                    model.setDoNotInterrupt(start: 22, end: 7)
                                } else {
                                    model.setDoNotInterrupt(start: nil, end: nil)
                                }
                            }
                        )
                    )
                    .toggleStyle(.switch)

                    if model.automations.doNotInterruptStartHour != nil,
                        model.automations.doNotInterruptEndHour != nil
                    {
                        HStack(spacing: 14) {
                            schedulePicker(
                                "Quiet from",
                                selection: Binding(
                                    get: { model.automations.doNotInterruptStartHour ?? 22 },
                                    set: {
                                        model.setDoNotInterrupt(
                                            start: $0,
                                            end: model.automations.doNotInterruptEndHour ?? 7
                                        )
                                    }
                                )
                            )
                            schedulePicker(
                                "Quiet until",
                                selection: Binding(
                                    get: { model.automations.doNotInterruptEndHour ?? 7 },
                                    set: {
                                        model.setDoNotInterrupt(
                                            start: model.automations.doNotInterruptStartHour ?? 22,
                                            end: $0
                                        )
                                    }
                                )
                            )
                        }
                    }

                    HStack {
                        Text("Power source")
                            .font(.system(size: 12, weight: .semibold))
                        Spacer()
                        Picker(
                            "Power source",
                            selection: Binding(
                                get: { model.automations.powerSourceRule },
                                set: { model.setPowerSourceRule($0) }
                            )
                        ) {
                            ForEach(PowerSourceRule.allCases) { rule in
                                Text(rule.title).tag(rule)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 200)
                    }
                    .padding(.horizontal, 14)
                    .frame(height: 44)
                    .background(Theme.panel, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.line))
                }
            }
        }
    }

    private var lockScreenSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            automationHeader(
                title: "Lock Screen",
                subtitle: "Assign a different video for the lock screen when the native wallpaper host is active.",
                enabled: true,
                expanded: model.lockAutomationExpanded,
                onEnable: { _ in },
                onToggleExpand: { model.lockAutomationExpanded.toggle() },
                showsEnable: false
            )

            if model.lockAutomationExpanded {
                AutomationSlotCard(
                    symbol: "lock.fill",
                    title: "Lock Screen",
                    detail: model.wallpaperHostMode == .native
                        ? "Choose wallpaper"
                        : "Needs macOS 26 native host",
                    footnote: "Idle / lock surface",
                    asset: model.asset(for: model.automations.lockScreenWallpaperID),
                    height: Self.cardHeight
                ) {
                    model.automationPickSlot = .lock
                }
                .frame(width: Self.cardWidth)
                .opacity(model.wallpaperHostMode == .native ? 1 : 0.55)
                .disabled(model.wallpaperHostMode != .native)
            }
        }
    }

    private func weekdayName(_ index: Int) -> String {
        ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"][index]
    }

    private func automationHeader(
        title: String,
        subtitle: String,
        enabled: Bool,
        expanded: Bool,
        onEnable: @escaping (Bool) -> Void,
        onToggleExpand: @escaping () -> Void,
        showsEnable: Bool = true
    ) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            HStack(spacing: 10) {
                if showsEnable {
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
                }
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
