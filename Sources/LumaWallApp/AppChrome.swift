import AppKit
import LumaWallCore
import SwiftUI

struct AtmosphereBackground: View {
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

struct AppChrome: View {
    @Bindable var model: AppModel

    var body: some View {
        HStack(spacing: 16) {
            Button {
                model.section = .home
            } label: {
                HStack(spacing: 8) {
                    BrandMark(size: 30)
                    Text(L10n.appName)
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                }
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .focusable(false)
            .help(L10n.home)
            .accessibilityLabel(L10n.brandHome)

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
                    // Keep the tab keyboard-focusable, but suppress SwiftUI's
                    // bright blue focus plate; the white capsule already conveys
                    // the selected destination in this custom navigation bar.
                    .focusEffectDisabled()
                    .accessibilityLabel(item.title)
                    .accessibilityAddTraits(model.section == item ? [.isSelected] : [])
                }
            }
            .padding(4)
            .background(.black.opacity(0.24), in: Capsule())
            .overlay(Capsule().stroke(Theme.line))
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text("Main navigation"))

            Spacer(minLength: 10)

            LibrarySearchField(text: $model.searchText, onSubmit: { model.section = .library })
                .frame(width: 188, height: 28)
                .padding(.horizontal, 10)
                .frame(height: 36)
                .background(.white.opacity(0.06), in: Capsule())
                .overlay(Capsule().stroke(Theme.line))
                .accessibilityLabel(L10n.search)
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
            .help(model.isPaused ? L10n.resume : L10n.pause)
            .accessibilityLabel(model.isPaused ? L10n.resume : L10n.pause)
            .keyboardShortcut("p", modifiers: [.command])

            Button(action: model.chooseVideos) {
                Image(systemName: "plus")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 36, height: 36)
                    .background(.white.opacity(0.10), in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help(L10n.importVideos)
            .accessibilityLabel(L10n.importVideos)
            .keyboardShortcut("i", modifiers: [.command])
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
struct ChromeHitSurface: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { ChromeHitView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

final class ChromeHitView: NSView {
    override nonisolated var mouseDownCanMoveWindow: Bool { false }
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

struct LibrarySearchField: NSViewRepresentable {
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
