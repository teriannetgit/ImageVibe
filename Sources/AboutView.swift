import SwiftUI

/// One open-source component and its license texts, from Resources/Acknowledgements.json.
struct Acknowledgement: Decodable, Identifiable {
    struct Notice: Decodable, Hashable {
        let title: String
        let body: String
    }

    let name: String
    let version: String
    let url: String
    let license: String
    let notices: [Notice]

    var id: String { name }

    static func bundled() -> [Acknowledgement] {
        guard let url = Bundle.main.url(forResource: "Acknowledgements", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([Acknowledgement].self, from: data)) ?? []
    }
}

struct AboutView: View {
    private let acknowledgements = Acknowledgement.bundled()
    private let models: [(name: String, holder: String)] = [
        ("Bonsai Image 4B · Ternary", "Prism ML, Inc."),
        ("FLUX.2 [klein] 4B", "Black Forest Labs"),
        ("Qwen3-4B text encoder", "Alibaba Cloud"),
        ("FLUX.2 small decoder", "Black Forest Labs · remapped for MLX by Duration AI")
    ]

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            credits
        }
        .frame(width: 760, height: 520)
        .background(Darkroom.canvas)
        .preferredColorScheme(.dark)
        .tint(Darkroom.edgePrint)
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 88, height: 88)
                .shadow(color: .black.opacity(0.5), radius: 12, y: 6)
                .accessibilityHidden(true)
                .padding(.bottom, 18)
            Text("ImageVibe")
                .font(.title.weight(.semibold))
                .foregroundStyle(Darkroom.text)
            Text(verbatim: "Version \(Self.version)")
                .font(.callout.monospacedDigit())
                .foregroundStyle(Darkroom.textSecondary)
                .textSelection(.enabled)
                .padding(.top, 4)
            Text("Images made on your Mac, offline, with Bonsai Image.")
                .font(.callout)
                .foregroundStyle(Darkroom.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 14)
            Spacer()
            Text("Created using Bonsai Image by Prism ML.")
                .font(.caption.weight(.medium))
                .foregroundStyle(Darkroom.edgePrint)
                .fixedSize(horizontal: false, vertical: true)
            // Copied into the app from Resources/teriannet.png; the logo is skipped if it is missing.
            Link(destination: URL(string: "https://teriannet.com/")!) {
                HStack(spacing: 10) {
                    if let url = Bundle.main.url(forResource: "teriannet", withExtension: "png"),
                       let logo = NSImage(contentsOf: url) {
                        Image(nsImage: logo).resizable().frame(width: 32, height: 32)
                    }
                    Text("Made by Teriannet Group Inc.")
                        .font(.callout)
                        .foregroundStyle(Darkroom.textSecondary)
                }
            }
            .padding(.top, 18)
        }
        .padding(28)
        .frame(width: 250, alignment: .leading)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Darkroom.panel)
        .overlay(alignment: .bottomTrailing) {
            // Watermark: bleeds off the bottom-right corner, clipped to the sidebar.
            VibeMark()
                .fill(Darkroom.edgePrint.opacity(0.07))
                .frame(width: 340, height: 340)
                .offset(x: 96, y: 40)
                .accessibilityHidden(true)
        }
        .clipped()
        .overlay(alignment: .trailing) { Rectangle().fill(Darkroom.hairline).frame(width: 1) }
    }

    private static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "–"
        let build = info?["CFBundleVersion"] as? String ?? "–"
        return "\(short) (\(build))"
    }

    // MARK: Credits

    private var credits: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                heading("Models")
                VStack(spacing: 0) {
                    ForEach(models, id: \.name) { model in
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(model.name).foregroundStyle(Darkroom.text)
                                Text(model.holder).font(.callout).foregroundStyle(Darkroom.textSecondary)
                            }
                            Spacer()
                            LicenseTag(text: "Apache 2.0")
                        }
                        .padding(.vertical, 10)
                        if model.name != models.last?.name { Divider().overlay(Darkroom.hairline) }
                    }
                }
                .padding(.horizontal, 14)
                .background(Darkroom.panel, in: .rect(cornerRadius: 10))
                Text("ImageVibe is an independent app. It is not affiliated with or endorsed by Prism ML, Black Forest Labs, Alibaba Cloud, Duration AI, Hugging Face or Apple. Names and marks belong to their owners. The model’s own LICENSE and NOTICE.md are saved beside it in the model folder.")
                    .font(.callout)
                    .foregroundStyle(Darkroom.textSecondary)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 12)

                heading("Open-source software", detail: "\(acknowledgements.count) components")
                    .padding(.top, 30)
                VStack(spacing: 0) {
                    ForEach(acknowledgements) { item in
                        AcknowledgementRow(item: item)
                        if item.id != acknowledgements.last?.id { Divider().overlay(Darkroom.hairline) }
                    }
                }
                .padding(.horizontal, 14)
                .background(Darkroom.panel, in: .rect(cornerRadius: 10))
            }
            .padding(.horizontal, 30)
            .padding(.vertical, 28)
        }
        .scrollIndicators(.automatic)
    }

    private func heading(_ title: String, detail: String? = nil) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.title3.weight(.semibold)).foregroundStyle(Darkroom.text)
            Spacer()
            if let detail { Text(detail).font(.callout).foregroundStyle(Darkroom.textSecondary) }
        }
        .padding(.bottom, 10)
    }
}

/// A package row that opens to show its license and notice texts.
private struct AcknowledgementRow: View {
    let item: Acknowledgement
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeOut(duration: 0.2)) { expanded.toggle() }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Darkroom.textSecondary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                    Text(item.name).foregroundStyle(Darkroom.text)
                    Text(item.version)
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(Darkroom.textSecondary)
                    Spacer()
                    LicenseTag(text: item.license)
                }
                .padding(.vertical, 10)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityValue(expanded ? "Expanded" : "Collapsed")
            if expanded {
                VStack(alignment: .leading, spacing: 10) {
                    if let url = URL(string: item.url) {
                        Link(item.url, destination: url).font(.callout)
                    }
                    ForEach(item.notices, id: \.self) { notice in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(notice.title)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Darkroom.textSecondary)
                            Text(notice.body)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(Darkroom.text.opacity(0.85))
                                .lineSpacing(2)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(12)
                                .background(Darkroom.canvas, in: .rect(cornerRadius: 8))
                        }
                    }
                }
                .padding(.leading, 22)
                .padding(.bottom, 14)
            }
        }
    }
}

private struct LicenseTag: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption.weight(.medium))
            .foregroundStyle(Darkroom.edgePrint)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .overlay(Capsule().strokeBorder(Darkroom.edgePrint.opacity(0.4)))
    }
}

/// The app icon's picture and sparkles as one silhouette, for watermarks. Geometry follows Resources/AppIcon.icon/Assets/*.svg (1024 grid).
nonisolated struct VibeMark: Shape {
    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height) / 1024
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * s, y: rect.minY + y * s) }

        let picture = Path(roundedRect: CGRect(origin: p(212, 292), size: CGSize(width: 560 * s, height: 520 * s)),
                           cornerRadius: 56 * s)

        // Four-point sparkle centred on (cx, cy): arm length r, waist w
        var sparkles = Path()
        func sparkle(_ cx: CGFloat, _ cy: CGFloat, r: CGFloat, w: CGFloat) {
            sparkles.move(to: p(cx, cy - r))
            sparkles.addCurve(to: p(cx + r, cy), control1: p(cx + w * 0.24, cy - w), control2: p(cx + w, cy - w * 0.24))
            sparkles.addCurve(to: p(cx, cy + r), control1: p(cx + w, cy + w * 0.24), control2: p(cx + w * 0.24, cy + w))
            sparkles.addCurve(to: p(cx - r, cy), control1: p(cx - w * 0.24, cy + w), control2: p(cx - w, cy + w * 0.24))
            sparkles.addCurve(to: p(cx, cy - r), control1: p(cx - w, cy - w * 0.24), control2: p(cx - w * 0.24, cy - w))
            sparkles.closeSubpath()
        }
        sparkle(736, 302, r: 150, w: 50)
        sparkle(858, 512, r: 60, w: 20)
        return picture.union(sparkles)
    }
}
