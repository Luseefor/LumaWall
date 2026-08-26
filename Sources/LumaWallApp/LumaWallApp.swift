import AppKit
import LumaWallCore
import SwiftUI

@main
struct LumaWallApp: App {
    @State private var model = AppModel()
    var body: some Scene {
        WindowGroup("LumaWall") { ContentView(model: model).frame(minWidth: 920, minHeight: 620) }
            .defaultSize(width: 1_180, height: 760)
    }
}

private enum Theme {
    static let background = Color(red: 0.027, green: 0.034, blue: 0.047)
    static let panel = Color.white.opacity(0.055)
    static let line = Color.white.opacity(0.09)
    static let accent = Color(red: 0.55, green: 0.43, blue: 1)
}

private struct ContentView: View {
    @Bindable var model: AppModel
    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            VStack(spacing: 0) {
                TopBar(model: model)
                Rectangle().fill(Theme.line).frame(height: 1)
                content
            }
        }
        .preferredColorScheme(.dark).tint(Theme.accent)
        .dropDestination(for: URL.self) { urls, _ in model.importVideos(urls); return true }
        .alert(model.alertTitle, isPresented: $model.showsAlert) { Button("OK", role: .cancel) {} } message: { Text(model.alertMessage) }
        .sheet(item: $model.previewAsset) { Preview(asset: $0) }
        .overlay { if model.isImporting { ImportOverlay() } }
    }

    @ViewBuilder private var content: some View {
        switch model.section {
        case .home: Home(model: model)
        case .explore: Collection(model: model, explore: true)
        case .library: Collection(model: model, explore: false)
        case .displays: FeaturePage(title: "Displays", subtitle: "Give every screen its own atmosphere", symbol: "display.2", message: "Independent and synchronized display controls are being connected to LumaWall’s native engine.", action: "Import a wallpaper", handler: model.chooseVideos)
        case .playlists: FeaturePage(title: "Playlists", subtitle: "Let your desktop change with your day", symbol: "rectangle.stack.fill", message: "Build rotations for focus, rest, battery power, and time of day.", action: "Open Library") { model.section = .library }
        case .settings: FeaturePage(title: "Settings", subtitle: "Quiet, efficient, and personal", symbol: "leaf.fill", message: "LumaWall keeps media local and will adapt playback to battery, visibility, and thermal pressure.", action: "Browse Library") { model.section = .library }
        }
    }
}

private struct TopBar: View {
    @Bindable var model: AppModel
    var body: some View {
        HStack(spacing: 16) {
            Button { model.section = .home } label: {
                HStack(spacing: 10) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10).fill(.white)
                        Image(systemName: "waveform.path").font(.system(size: 17, weight: .bold)).foregroundStyle(.black)
                    }.frame(width: 36, height: 36)
                    Text("LumaWall").font(.system(size: 17, weight: .bold, design: .rounded))
                }.foregroundStyle(.white)
            }.buttonStyle(.plain).focusable(false).frame(width: 165, alignment: .leading)

            HStack(spacing: 3) {
                ForEach([AppModel.Section.home, .explore, .library]) { item in
                    Button {
                        model.section = item
                    } label: {
                        Text(item.rawValue).font(.system(size: 12, weight: model.section == item ? .semibold : .medium))
                            .padding(.horizontal, 12).frame(height: 34)
                            .background { if model.section == item { Capsule().fill(.white.opacity(0.95)) } }
                            .foregroundStyle(model.section == item ? .black : .white.opacity(0.66))
                    }.buttonStyle(.plain).focusable(false)
                }
            }.padding(4).background(.black.opacity(0.25), in: Capsule()).overlay(Capsule().stroke(Theme.line))
            Spacer(minLength: 8)
            utilityButton(.displays, symbol: "display.2")
            utilityButton(.playlists, symbol: "rectangle.stack.fill")
            utilityButton(.settings, symbol: "gearshape.fill")
            Button { model.section = .explore } label: {
                Image(systemName: "magnifyingglass").frame(width: 36, height: 36).background(.white.opacity(0.08), in: Circle())
            }.buttonStyle(.plain).focusable(false).help("Search")
            Button(action: model.chooseVideos) {
                Image(systemName: "plus").font(.system(size: 14, weight: .semibold)).frame(width: 36, height: 36).background(.white.opacity(0.1), in: Circle())
            }.buttonStyle(.plain).focusable(false).help("Import videos")
        }.padding(.horizontal, 22).frame(height: 66).background(.black.opacity(0.14))
    }

    private func utilityButton(_ section: AppModel.Section, symbol: String) -> some View {
        Button { model.section = section } label: {
            Image(systemName: symbol).frame(width: 36, height: 36)
                .background(model.section == section ? .white : .white.opacity(0.08), in: Circle())
                .foregroundStyle(model.section == section ? .black : .white.opacity(0.72))
        }.buttonStyle(.plain).focusable(false).help(section.rawValue)
    }
}

private struct Home: View {
    @Bindable var model: AppModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                Hero(asset: model.assets.last, preview: { if let asset = model.assets.last { model.previewAsset = asset } }, importAction: model.chooseVideos)
                    .padding(.horizontal, -28).padding(.top, -28)
                SectionTitle(title: "Recently added", subtitle: "Your newest wallpapers, ready offline") { model.section = .library }
                if model.assets.isEmpty { EmptyStrip(action: model.chooseVideos) }
                else {
                    ScrollView(.horizontal) {
                        HStack(spacing: 16) {
                            ForEach(model.assets.reversed()) { asset in
                                WallpaperCard(asset: asset, favorite: model.isFavorite(asset), preview: { model.previewAsset = asset }, toggleFavorite: { model.toggleFavorite(asset) }) { model.remove(asset) }.frame(width: 270)
                            }
                        }
                    }.scrollIndicators(.hidden)
                }
                HStack(spacing: 16) {
                    FeatureCard(symbol: "display.2", color: .cyan, title: "Every screen, independent", detail: "Set the mood for each display without duplicating your library.") { model.section = .displays }
                    FeatureCard(symbol: "leaf.fill", color: .green, title: "Energy aware", detail: "Designed to become still when motion is hidden or power matters.") { model.section = .settings }
                    FeatureCard(symbol: "rectangle.stack.fill", color: .purple, title: "Wallpaper rotation", detail: "Build collections for moments, schedules, and power states.") { model.section = .playlists }
                }
            }.padding(28)
        }
    }
}

private struct Hero: View {
    let asset: WallpaperAsset?
    let preview: () -> Void
    let importAction: () -> Void
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .bottomLeading) {
                surface.frame(width: geometry.size.width, height: geometry.size.height).clipped()
                LinearGradient(colors: [.clear, .black.opacity(0.84)], startPoint: .center, endPoint: .bottom)
                LinearGradient(colors: [.black.opacity(0.45), .clear], startPoint: .leading, endPoint: .trailing)
                VStack(alignment: .leading, spacing: 11) {
                    Text(asset == nil ? "YOUR WALLPAPER, IN MOTION" : "FEATURED IN YOUR LIBRARY").font(.system(size: 11, weight: .bold)).tracking(2).foregroundStyle(.white.opacity(0.62))
                    Text(asset?.name ?? "Make your desktop feel alive.").font(.system(size: 35, weight: .bold, design: .rounded)).lineLimit(1)
                    Text(asset.map(metadata) ?? "Private, local video wallpapers built for your Mac.").foregroundStyle(.white.opacity(0.72))
                    HStack(spacing: 10) {
                        Button(asset == nil ? "Import your first wallpaper" : "Preview", systemImage: asset == nil ? "plus" : "play.fill", action: asset == nil ? importAction : preview).buttonStyle(.borderedProminent).controlSize(.large)
                        if asset != nil { Button("Add more", systemImage: "plus", action: importAction).buttonStyle(.bordered).controlSize(.large) }
                    }
                }.padding(34)
            }
        }.frame(height: 360).clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous)).overlay(RoundedRectangle(cornerRadius: 26).stroke(Theme.line))
    }
    @ViewBuilder private var surface: some View {
        if let url = asset?.posterURL, let image = NSImage(contentsOf: url) { Image(nsImage: image).resizable().scaledToFill() }
        else {
            LinearGradient(colors: [Color.indigo.opacity(0.9), Color.purple.opacity(0.68), Color.cyan.opacity(0.3)], startPoint: .topLeading, endPoint: .bottomTrailing)
                .overlay(alignment: .topTrailing) { Circle().fill(.white.opacity(0.12)).frame(width: 420).blur(radius: 55).offset(x: 90, y: -110) }
        }
    }
    private func metadata(_ value: WallpaperAsset) -> String { "\(Int(value.pixelSize.width)) × \(Int(value.pixelSize.height))  ·  \(value.framesPerSecond.formatted(.number.precision(.fractionLength(0)))) FPS  ·  Local" }
}

private struct Collection: View {
    @Bindable var model: AppModel
    let explore: Bool
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if explore { ExploreBanner(model: model) }
                else {
                    HStack(alignment: .bottom) {
                        VStack(alignment: .leading, spacing: 5) { Text("Library").font(.system(size: 32, weight: .bold, design: .rounded)); Text("Everything installed on this Mac").foregroundStyle(.secondary) }
                        Spacer(); Stat(value: "\(model.assets.count)", label: "Wallpapers")
                        Button("Import Videos", systemImage: "plus", action: model.chooseVideos).buttonStyle(.borderedProminent).controlSize(.large)
                    }
                }
                HStack(spacing: 9) {
                    ForEach(AppModel.LibraryFilter.allCases) { filter in
                        FilterPill(title: filter.rawValue, symbol: filter.symbol, selected: model.libraryFilter == filter) {
                            withAnimation(.snappy(duration: 0.2)) { model.libraryFilter = filter }
                        }
                    }
                    Spacer(); Text("Newest first").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                }
                SectionTitle(title: explore ? "Explore your collection" : "Your wallpapers", subtitle: resultText)
                if model.filteredAssets.isEmpty { EmptyStrip(action: model.chooseVideos).frame(minHeight: 280) }
                else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 245, maximum: 360), spacing: 18)], spacing: 20) {
                        ForEach(model.filteredAssets) { asset in
                            WallpaperCard(asset: asset, favorite: model.isFavorite(asset), preview: { model.previewAsset = asset }, toggleFavorite: { model.toggleFavorite(asset) }) { model.remove(asset) }
                        }
                    }
                }
            }.padding(28)
        }
    }
    private var resultText: String { model.searchText.isEmpty ? "\(model.filteredAssets.count) local items" : "\(model.filteredAssets.count) results for “\(model.searchText)”" }
}

private struct ExploreBanner: View {
    @Bindable var model: AppModel
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color.teal.opacity(0.38), Color.indigo.opacity(0.42)], startPoint: .leading, endPoint: .trailing)
            HStack {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Explore").font(.system(size: 34, weight: .bold, design: .rounded))
                    Text("Search your private collection. Nothing leaves this Mac.").foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("Search wallpapers", text: $model.searchText).textFieldStyle(.plain)
                        if !model.searchText.isEmpty { Button { model.searchText = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).foregroundStyle(.secondary) }
                    }.padding(.horizontal, 13).frame(width: 310, height: 36).background(.black.opacity(0.25), in: Capsule()).overlay(Capsule().stroke(Theme.line))
                }
                Spacer(); Image(systemName: "sparkles.rectangle.stack.fill").font(.system(size: 68)).foregroundStyle(.white.opacity(0.14))
            }.padding(30)
        }.frame(height: 175).clipShape(RoundedRectangle(cornerRadius: 22)).overlay(RoundedRectangle(cornerRadius: 22).stroke(Theme.line))
    }
}

private struct WallpaperCard: View {
    let asset: WallpaperAsset
    let favorite: Bool
    let preview: () -> Void
    let toggleFavorite: () -> Void
    let remove: () -> Void
    @State private var hovering = false
    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            ZStack {
                if let url = asset.posterURL, let image = NSImage(contentsOf: url) { Image(nsImage: image).resizable().scaledToFill() }
                else { Rectangle().fill(.white.opacity(0.06)).overlay(Image(systemName: "film")) }
                if hovering { Color.black.opacity(0.25); Button(action: preview) { Image(systemName: "play.fill").font(.title3).frame(width: 44, height: 44).background(.white, in: Circle()).foregroundStyle(.black) }.buttonStyle(.plain) }
                VStack {
                    HStack {
                        Spacer()
                        Button(action: toggleFavorite) {
                            Image(systemName: favorite ? "heart.fill" : "heart").foregroundStyle(favorite ? .pink : .white)
                                .frame(width: 30, height: 30).background(.black.opacity(0.48), in: Circle())
                        }.buttonStyle(.plain)
                    }
                    Spacer()
                    HStack { Text("LOCAL").font(.system(size: 9, weight: .bold)).padding(.horizontal, 7).frame(height: 22).background(.black.opacity(0.62), in: Capsule()); Spacer() }
                }.padding(10)
            }.aspectRatio(16 / 10, contentMode: .fit).clipped().clipShape(RoundedRectangle(cornerRadius: 15)).onHover { hovering = $0 }
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(asset.name).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                    Text("\(Int(asset.pixelSize.width))×\(Int(asset.pixelSize.height)) · \(asset.framesPerSecond.formatted(.number.precision(.fractionLength(0)))) FPS").font(.system(size: 10.5)).foregroundStyle(.secondary)
                }
                Spacer(); Menu { Button("Preview", systemImage: "play.fill", action: preview); Button(favorite ? "Remove Favorite" : "Favorite", systemImage: favorite ? "heart.slash" : "heart", action: toggleFavorite); Divider(); Button("Remove", systemImage: "trash", role: .destructive, action: remove) } label: { Image(systemName: "ellipsis.circle") }.menuStyle(.borderlessButton)
            }
        }.padding(12).background(Theme.panel, in: RoundedRectangle(cornerRadius: 19)).overlay(RoundedRectangle(cornerRadius: 19).stroke(Theme.line)).contentShape(RoundedRectangle(cornerRadius: 19)).onTapGesture(perform: preview)
    }
}

private struct FeaturePage: View {
    let title: String, subtitle: String, symbol: String, message: String, action: String
    let handler: () -> Void
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 6) { Text(title).font(.system(size: 32, weight: .bold, design: .rounded)); Text(subtitle).foregroundStyle(.secondary) }
                ZStack {
                    LinearGradient(colors: [Theme.accent.opacity(0.2), Color.cyan.opacity(0.08)], startPoint: .topLeading, endPoint: .bottomTrailing)
                    VStack(spacing: 16) { Image(systemName: symbol).font(.system(size: 54, weight: .light)).foregroundStyle(.white.opacity(0.72)); Text(message).font(.title3).multilineTextAlignment(.center).foregroundStyle(.white.opacity(0.75)).frame(maxWidth: 560); Button(action, action: handler).buttonStyle(.borderedProminent).controlSize(.large) }.padding(50)
                }.frame(maxWidth: .infinity, minHeight: 380).clipShape(RoundedRectangle(cornerRadius: 24)).overlay(RoundedRectangle(cornerRadius: 24).stroke(Theme.line))
            }.padding(28)
        }
    }
}

private struct FeatureCard: View {
    let symbol: String, color: Color, title: String, detail: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 12) {
                Image(systemName: symbol).font(.title2).foregroundStyle(color).frame(width: 42, height: 42).background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                Text(title).font(.system(size: 16, weight: .bold)); Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(3); Spacer(minLength: 0)
                Label("Open", systemImage: "arrow.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.72))
            }.frame(maxWidth: .infinity, minHeight: 145, alignment: .topLeading).padding(18).background(Theme.panel, in: RoundedRectangle(cornerRadius: 18)).overlay(RoundedRectangle(cornerRadius: 18).stroke(Theme.line))
        }.buttonStyle(.plain)
    }
}

private struct EmptyStrip: View {
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 16) {
                Image(systemName: "plus").font(.title2).frame(width: 52, height: 52).background(.white.opacity(0.08), in: Circle())
                VStack(alignment: .leading, spacing: 4) { Text("Add your first wallpaper").font(.headline); Text("Drop an MP4, MOV, or M4V anywhere in this window").foregroundStyle(.secondary) }
                Spacer(); Text("Choose Video").fontWeight(.semibold)
            }.padding(22).background(Theme.panel, in: RoundedRectangle(cornerRadius: 18)).overlay(RoundedRectangle(cornerRadius: 18).stroke(style: StrokeStyle(lineWidth: 1, dash: [7])))
        }.buttonStyle(.plain)
    }
}

private struct SectionTitle: View {
    let title: String, subtitle: String
    var action: (() -> Void)? = nil
    var body: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 4) { Text(title).font(.system(size: 21, weight: .bold, design: .rounded)); Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary) }
            Spacer(); if let action { Button("See all", systemImage: "chevron.right", action: action).buttonStyle(.plain).foregroundStyle(.secondary) }
        }
    }
}

private struct FilterPill: View {
    let title, symbol: String
    let selected: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol).font(.system(size: 12, weight: .semibold)).padding(.horizontal, 13).frame(height: 34).background(selected ? .white : .white.opacity(0.06), in: Capsule()).foregroundStyle(selected ? .black : .white.opacity(0.72))
        }.buttonStyle(.plain)
    }
}

private struct Stat: View {
    let value, label: String
    var body: some View { VStack(alignment: .trailing, spacing: 2) { Text(value).font(.headline); Text(label).font(.caption).foregroundStyle(.secondary) }.padding(.trailing, 8) }
}

private struct ImportOverlay: View {
    var body: some View { ZStack { Color.black.opacity(0.48).ignoresSafeArea(); VStack(spacing: 12) { ProgressView().controlSize(.large); Text("Preparing wallpaper…").fontWeight(.semibold) }.padding(28).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18)) } }
}

private struct Preview: View {
    let asset: WallpaperAsset
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 0) {
            LoopingVideoView(url: asset.mediaURL).aspectRatio(16 / 9, contentMode: .fit).background(.black)
            HStack { VStack(alignment: .leading, spacing: 4) { Text(asset.name).font(.title2.bold()); Text("\(Int(asset.pixelSize.width))×\(Int(asset.pixelSize.height)) · \(asset.framesPerSecond.formatted(.number.precision(.fractionLength(0)))) FPS · silent").foregroundStyle(.secondary) }; Spacer(); Button("Done", action: dismiss.callAsFunction).keyboardShortcut(.cancelAction) }.padding(18)
        }.frame(width: 920, height: 600).preferredColorScheme(.dark)
    }
}
