import AppKit
import LumaWallCore
import SwiftUI

struct SettingsPage: View {
    @Bindable var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L10n.settings)
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                        .accessibilityAddTraits(.isHeader)
                    Text(L10n.settingsSubtitle)
                        .foregroundStyle(Theme.textDim)
                }

                settingsGroup(title: L10n.wallpaperHost, symbol: "rectangle.on.rectangle.angled") {
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

                settingsGroup(title: L10n.playbackEnergy, symbol: "leaf.fill") {
                    VStack(spacing: 0) {
                        ForEach(PowerProfile.allCases, id: \.self) { profile in
                            Button { model.setPowerProfile(profile) } label: {
                                HStack(spacing: 14) {
                                    Image(systemName: profile.symbol)
                                        .frame(width: 28, height: 28)
                                        .foregroundStyle(model.powerProfile == profile ? Theme.accent : .secondary)
                                        .accessibilityHidden(true)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(profile.label).fontWeight(.semibold)
                                        Text(profile.detail)
                                            .font(.system(size: 11))
                                            .foregroundStyle(Theme.textDim)
                                    }
                                    Spacer()
                                    Image(systemName: model.powerProfile == profile ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(model.powerProfile == profile ? Theme.accent : Color.white.opacity(0.22))
                                        .accessibilityHidden(true)
                                }
                                .contentShape(Rectangle())
                                .padding(.vertical, 11)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(profile.label)
                            .accessibilityHint(profile.detail)
                            .accessibilityAddTraits(model.powerProfile == profile ? [.isSelected] : [])
                            if profile != PowerProfile.allCases.last {
                                Divider().overlay(Theme.line)
                            }
                        }
                        Divider().overlay(Theme.line)
                        settingsRow(
                            title: L10n.reduceMotion,
                            detail: model.reduceMotionActive
                                ? "System Reduce Motion is on. Live video stays on a still frame."
                                : "Follows System Settings → Accessibility → Display → Reduce motion.",
                            symbol: "figure.walk.motion"
                        ) {
                            Text(model.reduceMotionActive ? "On" : "Off")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(model.reduceMotionActive ? Theme.accent : Theme.textDim)
                                .accessibilityHidden(true)
                        }
                        Divider().overlay(Theme.line)
                        settingsRow(
                            title: L10n.pauseObscured,
                            detail: "Stops that screen when a window covers about 92% of it.",
                            symbol: "rectangle.slash"
                        ) {
                            Toggle(L10n.pauseObscured, isOn: Binding(
                                get: { model.pauseWhenObscured },
                                set: { model.setPauseWhenObscured($0) }
                            ))
                            .labelsHidden()
                            .accessibilityLabel(L10n.pauseObscured)
                        }
                        Divider().overlay(Theme.line)
                        settingsRow(
                            title: L10n.pauseLock,
                            detail: "Stops live video behind the lock screen. The still poster stays.",
                            symbol: "lock.fill"
                        ) {
                            Toggle(L10n.pauseLock, isOn: Binding(
                                get: { model.pauseOnLock },
                                set: { model.setPauseOnLock($0) }
                            ))
                            .labelsHidden()
                            .accessibilityLabel(L10n.pauseLock)
                        }
                        Divider().overlay(Theme.line)
                        settingsRow(
                            title: L10n.stillDesktop,
                            detail: model.wallpaperHostMode == .native
                                ? "Keeps the desktop still. Lock screen and screen saver can keep live video through the wallpaper extension."
                                : "Hides the live overlay on the desktop. System Settings still has the poster.",
                            symbol: "photo"
                        ) {
                            Toggle(L10n.stillDesktop, isOn: Binding(
                                get: { model.hideDesktopVideo },
                                set: { model.setHideDesktopVideo($0) }
                            ))
                            .labelsHidden()
                            .accessibilityLabel(L10n.stillDesktop)
                        }
                    }
                }

                settingsGroup(title: L10n.energyLog, symbol: "bolt.heart.fill") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(L10n.energyLogDetail)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.textDim)
                            .fixedSize(horizontal: false, vertical: true)
                        if let report = model.energySoakReport {
                            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                                statusCell(title: "Duration", value: String(format: "%.1f h", report.durationHours))
                                statusCell(title: "Samples", value: "\(report.sampleCount)")
                                statusCell(title: "Avg CPU", value: String(format: "%.2f%%", report.averageProcessCPU))
                                statusCell(title: "Peak CPU", value: String(format: "%.1f%%", report.peakProcessCPU))
                                statusCell(title: "Avg RAM", value: String(format: "%.0f MB", report.averageMemoryMB))
                                statusCell(title: "Avg decoders", value: String(format: "%.2f", report.averageDecoders))
                                statusCell(
                                    title: "24h mark",
                                    value: report.meets24HourGate ? "Met" : "In progress"
                                )
                                statusCell(
                                    title: "Battery Δ",
                                    value: report.batteryDeltaPercent.map { "\($0)%" } ?? "—"
                                )
                            }
                        } else {
                            Text("No samples yet. Start a 24h window while wallpapers play.")
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.textDim)
                        }
                        HStack(spacing: 10) {
                            GhostButton(L10n.startSoak, symbol: "timer") { model.startEnergySoak() }
                            GhostButton(L10n.copyProof, symbol: "doc.on.doc") { model.copyEnergyProof() }
                            GhostButton(L10n.resetSoak, symbol: "arrow.counterclockwise") { model.resetEnergySoak() }
                        }
                    }
                }

                settingsGroup(title: L10n.diagnostics, symbol: "stethoscope") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(L10n.diagnosticsDetail)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.textDim)
                            .fixedSize(horizontal: false, vertical: true)

                        if model.lastSessionEndedUncleanly {
                            HStack(spacing: 10) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(Theme.warm)
                                    .accessibilityHidden(true)
                                Text("The previous session did not shut down cleanly. The report below has details.")
                                    .font(.system(size: 12, weight: .medium))
                            }
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Theme.warm.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }

                        if model.crashReports.isEmpty {
                            Text("No crashes recorded. LumaWall has been shutting down cleanly.")
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.textDim)
                        } else {
                            VStack(spacing: 0) {
                                ForEach(model.crashReports.prefix(5)) { report in
                                    HStack(spacing: 14) {
                                        Image(systemName: report.kind == .uncleanShutdown ? "bolt.slash" : "ladybug.fill")
                                            .frame(width: 28, height: 28)
                                            .foregroundStyle(.secondary)
                                            .accessibilityHidden(true)
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(report.headline).fontWeight(.semibold)
                                            Text(report.date.formatted(date: .abbreviated, time: .shortened))
                                                .font(.system(size: 11))
                                                .foregroundStyle(Theme.textDim)
                                        }
                                        Spacer()
                                        GhostButton("Copy", symbol: "doc.on.doc") { model.copyCrashReport(report) }
                                    }
                                    .padding(.vertical, 9)
                                    .accessibilityElement(children: .combine)
                                    if report.id != model.crashReports.prefix(5).last?.id {
                                        Divider().overlay(Theme.line)
                                    }
                                }
                            }
                        }

                        HStack(spacing: 10) {
                            GhostButton("Show in Finder", symbol: "folder") { model.revealCrashReports() }
                            if !model.crashReports.isEmpty {
                                GhostButton("Clear reports", symbol: "trash") { model.clearCrashReports() }
                            }
                        }
                    }
                }

                settingsGroup(title: L10n.app, symbol: "app.badge") {
                    settingsRow(
                        title: L10n.launchAtLogin,
                        detail: "Starts LumaWall in the background after you sign in.",
                        symbol: "power"
                    ) {
                        Toggle(
                            L10n.launchAtLogin,
                            isOn: Binding(
                                get: { model.launchAtLogin },
                                set: { model.setLaunchAtLogin($0) }
                            )
                        )
                        .labelsHidden()
                        .accessibilityLabel(L10n.launchAtLogin)
                    }
                }

                settingsGroup(title: L10n.storage, symbol: "internaldrive.fill") {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(spacing: 12) {
                            StatPill(title: "Process RAM", value: String(format: "%.0f MB", model.processMemoryMB))
                            StatPill(title: "Active decoders", value: "\(model.activeDecoderCount)")
                            StatPill(title: "Library on disk", value: String(format: "%.0f MB", model.libraryDiskMB))
                            StatPill(title: "Wallpapers", value: "\(model.assets.count)")
                            Spacer()
                        }
                        Divider().overlay(Theme.line)
                        HStack(spacing: 10) {
                            GhostButton(L10n.clearRAM, symbol: "memorychip") { model.clearMemoryCache() }
                            GhostButton(L10n.clearDisk, symbol: "externaldrive") { model.clearDiskCache() }
                        }
                        Text("Clear RAM drops decoders and temporary caches. Imported videos stay on disk. Matching multi-display videos share one decoder on the overlay host.")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textDim)
                    }
                }

                settingsGroup(title: L10n.status, symbol: "info.circle") {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                        statusCell(title: "Playback", value: model.playbackStopped ? "Paused" : (model.activeByDisplay.isEmpty ? "Idle" : "Live"))
                        statusCell(title: "Displays", value: "\(model.activeByDisplay.count) of \(model.displays.count) live")
                        statusCell(title: "Energy", value: model.powerProfile.label)
                        statusCell(title: "Automations", value: automationStatus)
                        statusCell(title: "App CPU", value: String(format: "%.1f%%", model.processCPUPercent))
                        statusCell(title: "System CPU", value: String(format: "%.1f%%", model.systemCPUPercent))
                        statusCell(title: "Battery", value: model.isOnBattery ? "\(model.batteryPercent)% battery" : "Power adapter")
                        statusCell(title: "RAM", value: String(format: "%.0f MB", model.processMemoryMB))
                        statusCell(title: "Decoders", value: "\(model.activeDecoderCount)")
                        statusCell(title: "Reduce Motion", value: model.reduceMotionActive ? "On (still frame)" : "Off")
                        statusCell(
                            title: "Energy soak",
                            value: model.energySoakReport.map {
                                $0.meets24HourGate ? "24h met" : String(format: "%.1fh", $0.durationHours)
                            } ?? "Idle"
                        )
                    }
                }

                HStack(spacing: 14) {
                    BrandMark(size: 52)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L10n.appName).font(.headline)
                        Text(L10n.tagline)
                            .font(.caption).foregroundStyle(Theme.textDim)
                        Text("v0.4.0").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .combine)
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.panel, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(Theme.line))
            }
            .padding(28)
        }
        .reportsDiagnosticsVisibility(to: model)
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
                .accessibilityAddTraits(.isHeader)
            content()
                .padding(16)
                .background(Theme.panel, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 18).stroke(Theme.line))
        }
        .accessibilityElement(children: .contain)
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
                .accessibilityHidden(true)
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
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
        .accessibilityHint(detail)
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
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title): \(value)")
    }

}
