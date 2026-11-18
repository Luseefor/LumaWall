import AppKit
import CoreGraphics
import Darwin
import IOKit.ps
import LumaWallCore
import Observation
import UniformTypeIdentifiers

extension AppModel {
    func startEnergySoak() {
        Task {
            do {
                try await energyLogStore.startSoak()
                await refreshEnergyReport()
                present("Energy Log", "24-hour sample window started. Samples append while LumaWall runs.")
            } catch {
                present("Energy Log", error.localizedDescription)
            }
        }
    }

    func resetEnergySoak() {
        Task {
            do {
                try await energyLogStore.clearSoak()
                await refreshEnergyReport()
                present("Energy Log", "Sample window cleared. Rolling 24h samples remain.")
            } catch {
                present("Energy Log", error.localizedDescription)
            }
        }
    }

    func copyEnergyProof() {
        guard let proof = energySoakReport?.proofSummary else {
            present("Energy Log", "Start a sample window and wait for readings before copying.")
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(proof, forType: .string)
        present("Energy Log", energySoakReport?.meets24HourGate == true
            ? "Copied 24h energy report to the clipboard."
            : "Copied in-progress energy report to the clipboard.")
    }

    func refreshEnergyReport() async {
        energySoakReport = await energyLogStore.report()
    }

    // MARK: - Crash reporting (local only)

    private var appVersionString: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
        return "\(version) (\(build))"
    }

    func startCrashReporting() {
        let osVersion = ProcessInfo.processInfo.operatingSystemVersionString
        CrashMonitor.install(
            store: crashReportStore,
            appVersion: appVersionString,
            osVersion: osVersion
        )
        crashReportStore.ingestRawDumps(appVersion: appVersionString, osVersion: osVersion)
        let unclean = crashReportStore.beginSession(appVersion: appVersionString, osVersion: osVersion)
        crashReports = crashReportStore.reports()
        lastSessionEndedUncleanly = unclean != nil

        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { _ in
            CrashMonitor.markCleanShutdown()
        }
        willTerminateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.shutdown() }
        }
    }

    /// Invalidate timers, cancel pending work, and remove observers.
    /// Called on termination; also the safety net for previews/tests that
    /// recreate the model (which previously leaked all of the below).
    func shutdown() {
        playlistTimer?.invalidate()
        statsTimer?.invalidate()
        dayNightTimer?.invalidate()
        coverageTimer?.invalidate()
        playlistTimer = nil
        statsTimer = nil
        dayNightTimer = nil
        coverageTimer = nil
        coverageDebouncer?.cancel()
        coverageDebouncer = nil
        displayRefreshWorkItem?.cancel()
        displayRefreshWorkItem = nil
        nativeRestoreWorkItem?.cancel()
        nativeRestoreWorkItem = nil
        gameModeMonitor.stop()
        powerSourceRegistration.invalidate()
        let center = NotificationCenter.default
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        let distributedCenter = DistributedNotificationCenter.default()
        for observer in [appearanceObserver, reduceMotionObserver, screenObserver, willTerminateObserver].compactMap({ $0 }) {
            center.removeObserver(observer)
        }
        // Tokens originate from default, workspace, and distributed centers;
        // removing from a center that doesn't own the token is a harmless no-op.
        for observer in automationObservers + coverageObservers + lockObservers + powerObservers {
            center.removeObserver(observer)
            workspaceCenter.removeObserver(observer)
            distributedCenter.removeObserver(observer)
        }
        automationObservers.removeAll()
        coverageObservers.removeAll()
        lockObservers.removeAll()
        powerObservers.removeAll()
    }

    func copyCrashReport(_ report: CrashReport) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report.formattedText, forType: .string)
        present("Diagnostics", "Crash report copied to the clipboard.")
    }

    func revealCrashReports() {
        NSWorkspace.shared.activateFileViewerSelecting([crashReportStore.directoryURL])
    }

    func clearCrashReports() {
        crashReportStore.clearAll()
        crashReports = []
        lastSessionEndedUncleanly = false
        present("Diagnostics", "Crash reports cleared.")
    }
}
