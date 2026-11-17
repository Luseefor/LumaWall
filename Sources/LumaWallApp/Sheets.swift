import AppKit
import LumaWallCore
import SwiftUI

struct AssignSheet: View {
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
                    PosterImage(url: selectedAsset?.posterURL, contentMode: contentMode)
                        .scaleEffect(composition.scale)
                        .rotationEffect(.degrees(composition.rotationDegrees))
                        .offset(x: composition.offset.x * 0.18, y: -composition.offset.y * 0.18)
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

struct PreviewSheet: View {
    @Bindable var model: AppModel
    let asset: WallpaperAsset
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            LoopingVideoView(
                url: NativeWallpaperDeployment.previewURL(for: asset, minPixelWidth: NativeWallpaperDeployment.PreviewSize.sheet),
                isSuspended: model.screenIsHidden
            )
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

struct PlaylistEditorSheet: View {
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
            set: { model.setPlaylistEditorName($0) }
        )
    }

    private var intervalBinding: Binding<Int> {
        Binding(
            get: { model.playlistEditor?.intervalMinutes ?? 30 },
            set: { model.setPlaylistEditorInterval($0) }
        )
    }

    private var shuffleBinding: Binding<Bool> {
        Binding(
            get: { model.playlistEditor?.shuffled ?? false },
            set: { model.setPlaylistEditorShuffled($0) }
        )
    }
}
