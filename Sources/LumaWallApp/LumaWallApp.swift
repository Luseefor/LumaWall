import AppKit
import LumaWallCore
import SwiftUI

@main
struct LumaWallApp: App {
    @State private var model = AppModel()
    var body: some Scene {
        WindowGroup("LumaWall") { ContentView(model: model).frame(minWidth: 980, minHeight: 650) }
            .defaultSize(width: 1_180, height: 760)
    }
}

private struct ContentView: View {
    @Bindable var model: AppModel
    private let background = Color(red: 0.035, green: 0.045, blue: 0.065)

    var body: some View {
        NavigationSplitView {
            List(AppModel.Section.allCases, selection: $model.section) { section in
                Label(section.rawValue, systemImage: section.symbol).tag(section)
            }
            .navigationTitle("LumaWall")
            .safeAreaInset(edge: .bottom) {
                Button(action: model.chooseVideos) { Label("Import Video", systemImage: "plus.circle.fill").frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent).padding()
            }
        } detail: {
            ZStack { background.ignoresSafeArea(); sectionContent }.preferredColorScheme(.dark)
        }
        .searchable(text: $model.searchText, prompt: "Search your wallpapers")
        .dropDestination(for: URL.self) { urls, _ in model.importVideos(urls); return true }
        .alert(model.alertTitle, isPresented: $model.showsAlert) { Button("OK", role: .cancel) {} } message: { Text(model.alertMessage) }
        .sheet(item: $model.previewAsset) { asset in WallpaperPreview(asset: asset) }
        .overlay {
            if model.isImporting {
                ZStack {
                    Color.black.opacity(0.45).ignoresSafeArea()
                    VStack(spacing: 12) { ProgressView().controlSize(.large); Text("Preparing wallpaper…").fontWeight(.semibold) }
                        .padding(28).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
                }
            }
        }
    }

    @ViewBuilder private var sectionContent: some View {
        switch model.section {
        case .home: library(title: "Your atmosphere", subtitle: "Private, local, and ready offline")
        case .library: library(title: "Library", subtitle: "Every video stored on this Mac")
        case .displays: placeholder("Displays", symbol: "display.2", detail: "Stable display sessions are the next engine milestone.")
        case .playlists: placeholder("Playlists", symbol: "rectangle.stack", detail: "Rotation and scheduling arrive after playback sessions.")
        case .settings: placeholder("Settings", symbol: "gearshape", detail: "Power, cache, startup, and diagnostics controls will live here.")
        }
    }

    private func library(title: String, subtitle: String) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(title).font(.system(size: 34, weight: .bold, design: .rounded))
                        Text(subtitle).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Import", systemImage: "plus", action: model.chooseVideos).buttonStyle(.borderedProminent)
                }
                if model.filteredAssets.isEmpty {
                    ContentUnavailableView {
                        Label("No wallpapers yet", systemImage: "film.stack")
                    } description: {
                        Text("Drop an MP4, MOV, or M4V here. LumaWall removes audio and prevents duplicate copies.")
                    } actions: { Button("Choose Video", action: model.chooseVideos) }
                    .frame(maxWidth: .infinity, minHeight: 380)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 250, maximum: 360), spacing: 18)], spacing: 20) {
                        ForEach(model.filteredAssets) { asset in
                            WallpaperCard(asset: asset, preview: { model.previewAsset = asset }) { model.remove(asset) }
                        }
                    }
                }
            }.padding(28)
        }
    }

    private func placeholder(_ title: String, symbol: String, detail: String) -> some View {
        ContentUnavailableView(title, systemImage: symbol, description: Text(detail))
    }
}

private struct WallpaperCard: View {
    let asset: WallpaperAsset
    let preview: () -> Void
    let remove: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            Group {
                if let url = asset.posterURL, let image = NSImage(contentsOf: url) { Image(nsImage: image).resizable().scaledToFill() }
                else { Rectangle().fill(.white.opacity(0.06)).overlay(Image(systemName: "film")) }
            }
            .aspectRatio(16 / 10, contentMode: .fit).clipShape(RoundedRectangle(cornerRadius: 15))
            .overlay(alignment: .bottomTrailing) {
                Button(action: preview) { Image(systemName: "play.fill").frame(width: 32, height: 32) }
                    .buttonStyle(.borderedProminent).buttonBorderShape(.circle).padding(9)
            }
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(asset.name).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                    Text("\(Int(asset.pixelSize.width))×\(Int(asset.pixelSize.height)) · \(asset.framesPerSecond.formatted(.number.precision(.fractionLength(0)))) FPS")
                        .font(.system(size: 10.5)).foregroundStyle(.secondary)
                }
                Spacer()
                Menu { Button("Remove", systemImage: "trash", role: .destructive, action: remove) } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton)
            }
        }
        .padding(12).background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 19))
        .overlay(RoundedRectangle(cornerRadius: 19).stroke(.white.opacity(0.09)))
    }
}

private struct WallpaperPreview: View {
    let asset: WallpaperAsset
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            LoopingVideoView(url: asset.mediaURL)
                .aspectRatio(16 / 9, contentMode: .fit)
                .background(.black)
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(asset.name).font(.title2.bold())
                    Text("\(Int(asset.pixelSize.width))×\(Int(asset.pixelSize.height)) · \(asset.framesPerSecond.formatted(.number.precision(.fractionLength(0)))) FPS · silent")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done", action: dismiss.callAsFunction).keyboardShortcut(.cancelAction)
            }
            .padding(18)
        }
        .frame(width: 920, height: 600)
        .preferredColorScheme(.dark)
    }
}
