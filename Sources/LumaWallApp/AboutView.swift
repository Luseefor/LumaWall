import AppKit
import SwiftUI

enum AboutWindow {
    static let id = "about"
}

enum AboutLinks {
    static let repositoryBase = "https://github.com/Luseefor/LumaWall"
    static let privacy = URL(string: "\(repositoryBase)/blob/main/PRIVACY.md")!
    static let terms = URL(string: "\(repositoryBase)/blob/main/TERMS.md")!
    static let security = URL(string: "\(repositoryBase)/blob/main/SECURITY.md")!
    static let releases = URL(string: "\(repositoryBase)/releases")!
}

struct AboutInfo: Equatable {
    let appName: String
    let version: String
    let build: String
    let licenseName: String
    let acknowledgements: String

    var versionDisplay: String {
        "Version \(version) (\(build))"
    }

    static func load(from bundle: Bundle = .main) -> AboutInfo {
        let info = bundle.infoDictionary ?? [:]
        let appName =
            (info["CFBundleDisplayName"] as? String)
            ?? (info["CFBundleName"] as? String)
            ?? L10n.appName
        let version = (info["CFBundleShortVersionString"] as? String) ?? "0.0.0"
        let build = (info["CFBundleVersion"] as? String) ?? "0"
        let licenseText = loadResource(named: "LICENSE", extension: nil, from: bundle)
        let noticesText =
            loadResource(named: "THIRD_PARTY_NOTICES", extension: "md", from: bundle)
            ?? "No third-party notices bundled."
        return AboutInfo(
            appName: appName,
            version: version,
            build: build,
            licenseName: licenseName(from: licenseText),
            acknowledgements: noticesText
        )
    }

    static func licenseName(from licenseText: String?) -> String {
        guard let licenseText else { return "Apache License 2.0" }
        let trimmed = licenseText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Apache License 2.0" }
        if trimmed.localizedCaseInsensitiveContains("Apache License")
            && trimmed.localizedCaseInsensitiveContains("Version 2.0")
        {
            return "Apache License 2.0"
        }
        if trimmed.localizedCaseInsensitiveContains("MIT License") {
            return "MIT License"
        }
        return
            trimmed
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first(where: { !$0.isEmpty }) ?? "Apache License 2.0"
    }

    private static func loadResource(named name: String, extension ext: String?, from bundle: Bundle) -> String? {
        guard let url = bundle.url(forResource: name, withExtension: ext),
            let text = try? String(contentsOf: url, encoding: .utf8)
        else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

struct AboutView: View {
    let info: AboutInfo
    @Environment(\.openURL) private var openURL

    init(info: AboutInfo = .load()) {
        self.info = info
    }

    var body: some View {
        VStack(spacing: 18) {
            headerSection
            acknowledgementsSection
            linksSection
        }
        .padding(.horizontal, 24)
        .padding(.top, 34)
        .padding(.bottom, 22)
        .frame(width: 480, height: 560)
        .background {
            aboutBackground
        }
        .preferredColorScheme(.dark)
        .tint(Theme.accent)
    }

    private var aboutBackground: some View {
        ZStack {
            LinearGradient(colors: [Theme.bgTop, Theme.bgBottom], startPoint: .topLeading, endPoint: .bottomTrailing)
            RadialGradient(
                colors: [Theme.accent.opacity(0.14), .clear],
                center: .topTrailing,
                startRadius: 10,
                endRadius: 300
            )
            RadialGradient(
                colors: [Theme.warm.opacity(0.06), .clear],
                center: .bottomLeading,
                startRadius: 10,
                endRadius: 260
            )
        }
        .ignoresSafeArea()
    }

    private var headerSection: some View {
        VStack(spacing: 10) {
            BrandMark(size: 72, glowing: true)

            VStack(spacing: 4) {
                Text(info.appName)
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .accessibilityAddTraits(.isHeader)

                Text(L10n.tagline)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textDim)
            }

            HStack(spacing: 8) {
                Text(info.versionDisplay)
                    .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(Theme.textDim)

                Text("·")
                    .foregroundStyle(Theme.textDim)
                    .accessibilityHidden(true)

                Text(info.licenseName)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 3)
                    .background(Theme.accent.opacity(0.14), in: Capsule())
                    .overlay(Capsule().stroke(Theme.accent.opacity(0.28), lineWidth: 0.75))
            }

            GhostButton("Check for Updates", symbol: "arrow.up.right.square") {
                openURL(AboutLinks.releases)
            }
            .padding(.top, 2)
        }
    }

    private var acknowledgementsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Acknowledgements", systemImage: "doc.text")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.88))
                .accessibilityAddTraits(.isHeader)

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(acknowledgementBlocks.enumerated()), id: \.offset) { _, block in
                        acknowledgementBlockView(block)
                    }
                }
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Theme.line))
        }
    }

    private enum NoticeBlock {
        case title(String)
        case heading(String)
        case paragraph(String)
    }

    private var acknowledgementBlocks: [NoticeBlock] {
        info.acknowledgements
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { block in
                if block.hasPrefix("## ") {
                    return .heading(String(block.dropFirst(3)))
                }
                if block.hasPrefix("# ") {
                    return .title(String(block.dropFirst(2)))
                }
                return .paragraph(block)
            }
    }

    @ViewBuilder
    private func acknowledgementBlockView(_ block: NoticeBlock) -> some View {
        switch block {
        case .title(let text):
            Text(text)
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
        case .heading(let text):
            Text(text)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.92))
                .padding(.top, 2)
        case .paragraph(let text):
            if let attributed = try? AttributedString(
                markdown: text,
                options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
            ) {
                Text(attributed)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.white.opacity(0.78))
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(text)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.white.opacity(0.78))
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var linksSection: some View {
        HStack(spacing: 14) {
            legalLink("Privacy", url: AboutLinks.privacy)
            linkSeparator
            legalLink("Terms", url: AboutLinks.terms)
            linkSeparator
            legalLink("Security", url: AboutLinks.security)
        }
        .font(.system(size: 12, weight: .medium))
        .padding(.vertical, 10)
        .padding(.horizontal, 18)
        .background(Theme.panel, in: Capsule())
        .overlay(Capsule().stroke(Theme.line))
    }

    private func legalLink(_ title: String, url: URL) -> some View {
        Link(destination: url) {
            HStack(spacing: 4) {
                Text(title)
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 9.5, weight: .semibold))
                    .opacity(0.75)
                    .accessibilityHidden(true)
            }
            .foregroundStyle(.white.opacity(0.86))
        }
        .accessibilityLabel("\(title) on GitHub")
    }

    private var linkSeparator: some View {
        Circle()
            .fill(Color.white.opacity(0.28))
            .frame(width: 3, height: 3)
            .accessibilityHidden(true)
    }
}
