import SwiftUI

@main struct ImageVibeApp: App {
    @State private var session = GenerationSession()
    @State private var roll = FilmRoll.standard()

    init() {
        if CommandLine.arguments.contains("--self-check") {
            do { try SelfChecks.run(); exit(0) }
            catch { print("SELF CHECK FAILED: \(error)"); exit(1) }
        }
    }

    var body: some Scene {
        Window("ImageVibe", id: "main") {
            ContentView().environment(session).environment(roll)
        }
        .defaultSize(width: 1120, height: 800)
        .windowToolbarStyle(.unified)
        .commands { AboutCommand() }
        Window("About ImageVibe", id: "about") {
            AboutView()
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
        Settings {
            SettingsView().environment(session)
        }
    }
}

/// Replaces the default About item with the app's own About window.
struct AboutCommand: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About ImageVibe") { openWindow(id: "about") }
        }
    }
}

/// The divider between the canvas and the film roll. Drag it to resize the roll; the width is remembered.
struct RollResizeHandle: View {
    @Binding var width: Double
    @State private var startWidth: Double?

    var body: some View {
        Rectangle()
            .fill(Darkroom.hairline)
            .frame(width: 1)
            .overlay {
                // A wider, invisible grab area around the 1-point line.
                Color.clear
                    .frame(width: 9)
                    .contentShape(.rect)
                    .onHover { inside in
                        if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                    }
                    .gesture(
                        DragGesture(coordinateSpace: .global)
                            .onChanged { value in
                                let start = startWidth ?? width
                                startWidth = start
                                width = min(max(start - value.translation.width, 170), 320)
                            }
                            .onEnded { _ in startWidth = nil }
                    )
            }
    }
}

struct ContentView: View {
    @Environment(GenerationSession.self) private var session
    @Environment(FilmRoll.self) private var roll
    @State private var prompt = ""
    @State private var unsaved: (picture: GeneratedPicture, request: GenerationRequest)?
    @AppStorage("composer.aspect") private var aspect = Aspect.square
    @AppStorage("composer.longEdge") private var longEdge = 512
    @AppStorage("composer.steps") private var steps = GenerationRequest.defaultSteps
    @AppStorage("composer.preciseDecode") private var preciseDecode = false
    @AppStorage("composer.seed") private var seed = 42
    @AppStorage("composer.lockSeed") private var lockSeed = false
    @AppStorage("window.showFilmRoll") private var showingRoll = true
    @State private var selectedID: UUID?
    @State private var choosingModel = false
    @State private var showingAdvanced = false
    @State private var showingSeedTip = false
    @AppStorage("window.rollWidth") private var rollWidth = 220.0

    private var selected: Frame? { roll.frames.first { $0.id == selectedID } }
    private var canGenerate: Bool {
        unsaved == nil && !session.running && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        // The film roll is a plain panel, not an inspector: an inspector runs up into the title bar at launch.
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                stage
                composer
            }
            .frame(minWidth: 760)
            RollResizeHandle(width: $rollWidth)
            FilmRollView(selection: $selectedID, onReuse: reuse, onError: { session.error = $0 })
                .frame(width: rollWidth)
        }
        .background(Darkroom.canvas)
        .frame(minHeight: 560)
        .navigationTitle("ImageVibe")
        .navigationSubtitle(subtitle)
        // The bar's dark colour is painted from the content beneath the (transparent) title bar, not with
        // .toolbarBackground, whose view swallowed mouse-downs so the bar would not drag the window.
        .background {
            GeometryReader { proxy in
                Darkroom.panel
                    .frame(height: proxy.safeAreaInsets.top)
                    .offset(y: -proxy.safeAreaInsets.top)
            }
        }
        .preferredColorScheme(.dark)
        .tint(Darkroom.safelight)
        .sheet(isPresented: $choosingModel) { ModelPicker() }
        .onChange(of: prompt) { _, _ in session.warning = nil }
        // Closing the main window quits the app. About and Settings can close without quitting.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { note in
            // SwiftUI names the window from its scene id; titles also match Settings and About.
            guard let window = note.object as? NSWindow, window.identifier?.rawValue.hasPrefix("main") == true else { return }
            NSApp.terminate(nil)
        }
        .task {
            selectedID = roll.frames.first?.id
            if CommandLine.arguments.contains("--validate"), ProcessInfo.processInfo.environment["LATENT_BONSAI_LIVE"] == "1" {
                await session.validate()
            } else if NativeGenerator.defaultModelMissing() {
                choosingModel = true
            }
        }
    }

    private var subtitle: String {
        guard let selected, let index = roll.frames.firstIndex(of: selected) else { return "" }
        return "Frame \(roll.frames.count - index) of \(roll.frames.count)"
    }

    // MARK: Stage

    private var stage: some View {
        VStack(spacing: 0) {
            ZStack {
                // The empty canvas drags the window: the dark title bar is hard to tell apart from it.
                Color.clear
                    .contentShape(.rect)
                    .gesture(WindowDragGesture())
                    .allowsWindowActivationEvents(true)
                if let unsaved, let image = NSImage(data: unsaved.picture.png) {
                    Image(nsImage: image).resizable().scaledToFit().padding(32)
                        .accessibilityLabel("Unsaved image for: \(unsaved.request.prompt)")
                } else if let selected {
                    FrameImage(url: roll.imageURL(selected))
                        .shadow(color: .black.opacity(0.6), radius: 30, y: 10)
                        .onTapGesture(count: 2) { roll.openInPreview(selected) }
                        .help("Double-click to open in Preview")
                        .padding(32)
                        .accessibilityLabel("Image for: \(selected.request.prompt)")
                        .accessibilityAction(named: "Open in Preview") { roll.openInPreview(selected) }
                } else if let pending = session.pending {
                    Darkroom.field
                        .aspectRatio(CGFloat(pending.width) / CGFloat(pending.height), contentMode: .fit)
                        .padding(32)
                } else {
                    emptyStage
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            caption
                .padding(.horizontal, 32)
                .padding(.bottom, 20)
        }
    }

    private var emptyStage: some View {
        VStack(spacing: 10) {
            Image(systemName: "camera.aperture")
                .font(.system(size: 44, weight: .thin))
                .foregroundStyle(Darkroom.textSecondary)
                .padding(.bottom, 6)
            Text("Nothing developed yet")
                .font(.title2.weight(.semibold))
                .foregroundStyle(Darkroom.text)
            Text("Describe an image below and press Generate. A Draft image takes about 10 seconds.")
                .foregroundStyle(Darkroom.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
        }
    }

    @ViewBuilder private var caption: some View {
        if session.running {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(session.phase)
                    Spacer()
                    Text(session.fraction, format: .percent.precision(.fractionLength(0))).monospacedDigit()
                }
                .font(.callout)
                .foregroundStyle(Darkroom.text)
                ProgressView(value: session.fraction)
                    .progressViewStyle(.linear)
                Text("A generation can’t be stopped once it starts.")
                    .font(.caption)
                    .foregroundStyle(Darkroom.textSecondary)
            }
            .frame(maxWidth: 520)
        } else if let selected {
            VStack(alignment: .leading, spacing: 6) {
                Text(selected.request.prompt)
                    .foregroundStyle(Darkroom.text)
                    .lineLimit(2)
                    .textSelection(.enabled)
                HStack(spacing: 12) {
                    Text(Self.details(selected))
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(Darkroom.textSecondary)
                        .textSelection(.enabled)
                    Spacer()
                    Button("Reuse Prompt and Settings") { reuse(selected) }
                        .buttonStyle(.borderless)
                        .foregroundStyle(Darkroom.text)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    static func details(_ frame: Frame) -> String {
        let r = frame.request
        let seconds = frame.seconds.formatted(.number.precision(.fractionLength(1)))
        var parts = ["\(r.width) × \(r.height)", "\(r.steps) steps", "Seed \(r.seed)", "\(seconds) s"]
        if r.preciseDecode { parts.insert("Fine decode", at: 2) }
        return parts.joined(separator: "  ·  ")
    }

    // MARK: Composer

    private var composer: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let error = session.error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(Color(red: 1, green: 0.62, blue: 0.55))
                    .textSelection(.enabled)
            }
            if let unsaved {
                HStack {
                    Text("Your image is kept in memory until you save it. Keep this window open.")
                    Button("Retry Save") { saveResult() }
                    Button("Save As…") {
                        do {
                            if try roll.save(png: unsaved.picture.png, prompt: unsaved.request.prompt) {
                                self.unsaved = nil
                                session.error = nil
                            }
                        } catch { session.error = error.localizedDescription }
                    }
                }
            }
            if let warning = session.warning {
                Label(warning, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(Darkroom.edgePrint)
            }
            HStack(alignment: .bottom, spacing: 10) {
                TextField("Describe the image you want to make", text: $prompt, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .lineLimit(1...5)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                    .background(Darkroom.field, in: .rect(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Darkroom.hairline))
                    .onSubmit { if canGenerate { generate() } }
                    .accessibilityLabel("Prompt")
                Button(action: generate) {
                    Text(session.running ? "Developing…" : "Generate")
                        .fontWeight(.semibold)
                        .frame(minWidth: 96)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.extraLarge)
                .keyboardShortcut(.return, modifiers: .command)
                .help("Generate (⌘↩)")
                .disabled(!canGenerate)
            }
            settingsRow
                .disabled(session.running)
        }
        .padding(16)
        .background(Darkroom.panel)
        .overlay(alignment: .top) { Rectangle().fill(Darkroom.hairline).frame(height: 1) }
    }

    private var settingsRow: some View {
        HStack(spacing: 20) {
            Picker("Shape", selection: $aspect) {
                ForEach(Aspect.allCases) { option in
                    Text(option.ratio).accessibilityLabel(option.label).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("Shape of the image")
            Picker("Size", selection: $longEdge) {
                Text("Draft").tag(512)
                Text("Final").tag(1024)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("Draft is 512 pixels on the long edge, Final is 1024. Final takes about three times as long and uses much more memory.")
            Button {
                showingSeedTip = true
            } label: {
                Image(systemName: "info.circle")
            }
            .buttonStyle(.borderless)
            .help("About seeds from Draft to Final")
            .popover(isPresented: $showingSeedTip, arrowEdge: .bottom) { seedTip }
            Button {
                showingAdvanced = true
            } label: {
                Label(advancedSummary, systemImage: "slider.horizontal.3")
                    .foregroundStyle(Darkroom.text)
            }
            .help("Steps and decode precision")
            .popover(isPresented: $showingAdvanced, arrowEdge: .top) { advanced }
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                TextField("Seed", value: $seed, format: .number.grouping(.never))
                    .frame(width: 104)
                    .monospacedDigit()
                    .accessibilityLabel("Seed")
                Toggle(isOn: $lockSeed) {
                    Image(systemName: lockSeed ? "lock.fill" : "lock.open")
                        .foregroundStyle(Darkroom.text)
                }
                .toggleStyle(.button)
                .accessibilityLabel("Keep seed")
                .help(lockSeed ? "Seed kept: the next image reuses it" : "Each image gets a new seed. Lock to reuse this one.")
                Button {
                    seed = Int.random(in: 0...Int(UInt32.max))
                    lockSeed = true
                } label: {
                    Label("New Seed", systemImage: "dice").labelStyle(.iconOnly).foregroundStyle(Darkroom.text)
                }
                .help("Pick a new seed and keep it")
            }
        }
        .foregroundStyle(Darkroom.text)
        // Safelight red is kept for Generate; the setting controls stay neutral.
        .tint(Color(white: 0.4))
    }

    private var seedTip: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Seeds from Draft to Final").font(.headline)
            Text("A seed does not carry over exactly from Draft to Final. Draft and Final start from different-sized noise, so the same seed gives a similar but not identical picture.")
                .fixedSize(horizontal: false, vertical: true)
            Text("Tip: to preview Final quickly, set Advanced › Steps to 2. Once you like the result, raise it to 4 for the finished image.")
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.callout)
        .padding(16)
        .frame(width: 300)
    }

    private var advancedSummary: String {
        steps == GenerationRequest.defaultSteps && !preciseDecode ? "Advanced" : "\(steps) steps\(preciseDecode ? " · Fine" : "")"
    }

    private var advanced: some View {
        Form {
            Stepper("Steps: \(steps)", value: $steps, in: GenerationRequest.stepRange)
            Text("The model is tuned for 4 steps. Fewer is faster and rougher; more rarely helps.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Fine decode", isOn: $preciseDecode)
            Text("Decodes in full precision for slightly finer detail. Uses more memory.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Reset to Defaults") {
                steps = GenerationRequest.defaultSteps
                preciseDecode = false
            }
            .disabled(steps == GenerationRequest.defaultSteps && !preciseDecode)
        }
        .formStyle(.grouped)
        .frame(width: 300)
    }

    // MARK: Actions

    private func generate() {
        if !lockSeed { seed = Int.random(in: 0...Int(UInt32.max)) }
        let (width, height) = aspect.size(longEdge: longEdge)
        let settings = (prompt: prompt, steps: steps, seed: UInt64(max(0, seed)), precise: preciseDecode)
        Task {
            do {
                let request = try GenerationRequest(prompt: settings.prompt, width: width, height: height,
                                                    steps: settings.steps, seed: settings.seed,
                                                    preciseDecode: settings.precise)
                let picture = try await session.generate(request)
                unsaved = (picture, request)
                saveResult()
            } catch StudioError.missingModels {
                choosingModel = true
            } catch {
                session.error = error.localizedDescription
            }
        }
    }

    private func saveResult() {
        guard let unsaved else { return }
        do {
            selectedID = try roll.add(unsaved.picture, for: unsaved.request).id
            self.unsaved = nil
            session.error = nil
        } catch { session.error = error.localizedDescription }
    }

    private func reuse(_ frame: Frame) {
        let r = frame.request
        prompt = r.prompt
        steps = r.steps
        preciseDecode = r.preciseDecode
        seed = Int(r.seed)
        lockSeed = true
        longEdge = max(r.width, r.height)
        aspect = Aspect.allCases.first { $0.size(longEdge: longEdge) == (r.width, r.height) } ?? .square
    }

}

/// A full-size frame, decoded off the main thread.
struct FrameImage: View {
    let url: URL
    @State private var image: CGImage?

    var body: some View {
        Group {
            if let image {
                Image(decorative: image, scale: 1).resizable().interpolation(.high).scaledToFit()
            } else {
                Color.clear
            }
        }
        .task(id: url) { image = await Thumbnail.load(url, maxPixels: 2048) }
    }
}

// MARK: Film roll

struct FilmRollView: View {
    @Environment(FilmRoll.self) private var roll
    @Environment(GenerationSession.self) private var session
    @Binding var selection: UUID?
    let onReuse: (Frame) -> Void
    let onError: (String) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                // Always a point taller than the panel, so the roll always scrolls. A strip ending near the window's
                // bottom crossed the panel height at launch, and AppKit aborted when that toggled the scroller.
                ZStack(alignment: .top) {
                    Color.clear.containerRelativeFrame(.vertical) { height, _ in height + 1 }
                    LazyVStack(spacing: 0) {
                        if let pending = session.pending {
                            DevelopingFrame(request: pending, fraction: session.fraction)
                        }
                        ForEach(Array(roll.frames.enumerated()), id: \.element.id) { index, frame in
                            FrameCell(frame: frame, number: roll.frames.count - index, url: roll.imageURL(frame),
                                      selected: frame.id == selection)
                                .id(frame.id)
                                // Select on the first click; a plain count-2 tap would delay every single click.
                                .onTapGesture { selection = frame.id }
                                // A double-click takes the whole click sequence, so it selects as well as opening.
                                .simultaneousGesture(TapGesture(count: 2).onEnded {
                                    selection = frame.id
                                    roll.openInPreview(frame)
                                })
                                .contextMenu { menu(for: frame) }
                                // Drags the PNG file itself, so Finder, Mail and other apps take the image.
                                .onDrag { NSItemProvider(contentsOf: roll.imageURL(frame)) ?? NSItemProvider() }
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 10)
                    // Room for the leader as padding, not a view: a spacer view in the stack fed an inspector
                    // layout loop that crashed AppKit, and a scroll content margin swallowed clicks on frames.
                    .padding(.bottom, 10 + FilmStrip.leaderHeight)
                    .background(alignment: .top) {
                        // The strip body follows the content's height; the leader is a fixed-size view pinned to the
                        // bottom. Clipping the whole strip to a shape sized by the content redrew it on every delete.
                        VStack(spacing: 0) {
                            ZStack {
                                Darkroom.filmBase
                                HStack { Sprockets(); Spacer(); Sprockets() }
                            }
                            FilmLeader()
                                .frame(height: FilmStrip.leaderHeight)
                        }
                    }
                }
            }
            // Always shown, so the roll's width never changes. With space-taking scroll bars, a bar that came and
            // went as frames were deleted changed the width, which changed every frame's height, which toggled
            // the bar again: AppKit aborted that redraw loop.
            .scrollIndicators(.visible)
            .onChange(of: selection) { _, id in
                guard let id else { return }
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(id) }
            }
        }
        // Stays below the title bar: no colour under it, and frames never scroll up beneath it.
        .background(Darkroom.panel, ignoresSafeAreaEdges: [])
        .clipped()
        .overlay {
            if roll.frames.isEmpty && session.pending == nil {
                Text("Images you make appear here.")
                    .font(.callout)
                    .foregroundStyle(Darkroom.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(24)
            }
        }
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.upArrow) { move(by: -1) }
        .onKeyPress(.downArrow) { move(by: 1) }
        .onDeleteCommand { if let frame = roll.frames.first(where: { $0.id == selection }) { trash(frame) } }
    }

    @ViewBuilder private func menu(for frame: Frame) -> some View {
        Button("Open in Preview") { roll.openInPreview(frame) }
        Button("Copy Image") {
            do { try roll.copy(frame) } catch { onError(error.localizedDescription) }
        }
        Button("Reuse Prompt and Settings") { onReuse(frame) }
        Button("Save…") {
            do { try roll.save(frame) } catch { onError(error.localizedDescription) }
        }
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([roll.imageURL(frame)]) }
        Divider()
        Button("Move to Trash") { trash(frame) }
    }

    private func move(by offset: Int) -> KeyPress.Result {
        let ids = roll.frames.map(\.id)
        guard !ids.isEmpty else { return .ignored }
        let current = selection.flatMap { ids.firstIndex(of: $0) } ?? -offset
        selection = ids[min(max(current + offset, 0), ids.count - 1)]
        return .handled
    }

    private func trash(_ frame: Frame) {
        let index = roll.frames.firstIndex(of: frame) ?? 0
        do {
            try roll.trash(frame)
            if selection == frame.id {
                selection = roll.frames.isEmpty ? nil : roll.frames[min(index, roll.frames.count - 1)].id
            }
        } catch { onError(error.localizedDescription) }
    }
}

struct FrameCell: View {
    let frame: Frame
    let number: Int
    let url: URL
    let selected: Bool
    @State private var image: CGImage?

    var body: some View {
        VStack(spacing: 5) {
            ZStack {
                Darkroom.canvas
                if let image { Image(decorative: image, scale: 1).resizable().scaledToFit() }
            }
            .aspectRatio(CGFloat(frame.request.width) / CGFloat(frame.request.height), contentMode: .fit)
            .clipShape(.rect(cornerRadius: 2))
            .overlay {
                RoundedRectangle(cornerRadius: 2)
                    .strokeBorder(selected ? Darkroom.safelight : Darkroom.hairline, lineWidth: selected ? 2 : 1)
            }
            HStack {
                Text(verbatim: "\(number)")
                Spacer()
                Text(verbatim: "\(frame.request.width)×\(frame.request.height)")
            }
            .font(.caption2.monospacedDigit().weight(.medium))
            .foregroundStyle(Darkroom.edgePrint.opacity(selected ? 1 : 0.75))
        }
        .padding(.vertical, 7)
        .contentShape(.rect)
        .task(id: url) { image = await Thumbnail.load(url) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Frame \(number): \(frame.request.prompt)")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

/// The frame being generated, shown at the top of the roll.
struct DevelopingFrame: View {
    let request: GenerationRequest
    let fraction: Double

    var body: some View {
        VStack(spacing: 5) {
            Darkroom.field
                .aspectRatio(CGFloat(request.width) / CGFloat(request.height), contentMode: .fit)
                .overlay(alignment: .bottom) {
                    ProgressView(value: fraction).progressViewStyle(.linear).padding(8)
                }
                .clipShape(.rect(cornerRadius: 2))
                .overlay { RoundedRectangle(cornerRadius: 2).strokeBorder(Darkroom.safelight, lineWidth: 2) }
            HStack {
                Text("Developing")
                Spacer()
            }
            .font(.caption2.weight(.medium))
            .foregroundStyle(Darkroom.edgePrint)
        }
        .padding(.vertical, 7)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Generating image")
        .accessibilityValue(Text(fraction, format: .percent.precision(.fractionLength(0))))
    }
}

/// The film strip: straight for the frames, then trimmed into a leader tongue for the last `leaderHeight` points.
nonisolated struct FilmStrip: Shape {
    static let leaderHeight: CGFloat = 180

    func path(in rect: CGRect) -> Path {
        let start = rect.maxY - Self.leaderHeight   // where the leader begins
        let tongue = rect.minX + rect.width * 0.46  // left edge of the trimmed tongue
        let cut = start + 34
        let cutEnd = cut + 70
        let end = rect.maxY - 8
        let radius: CGFloat = 16
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: end - radius))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - radius, y: end), control: CGPoint(x: rect.maxX, y: end))
        path.addLine(to: CGPoint(x: tongue + radius, y: end))
        path.addQuadCurve(to: CGPoint(x: tongue, y: end - radius), control: CGPoint(x: tongue, y: end))
        path.addLine(to: CGPoint(x: tongue, y: cutEnd))
        // The long curved trim back out to full width.
        path.addCurve(to: CGPoint(x: rect.minX, y: cut),
                      control1: CGPoint(x: tongue, y: cutEnd - 36),
                      control2: CGPoint(x: rect.minX + rect.width * 0.14, y: cut + 4))
        path.closeSubpath()
        return path
    }
}

/// The trimmed start of the film: a fixed-size view, so it never depends on how many frames there are.
struct FilmLeader: View {
    var body: some View {
        ZStack {
            Darkroom.filmBase
            HStack { Sprockets(); Spacer(); Sprockets() }
        }
        .clipShape(FilmStrip())
    }
}

/// Film-strip perforations down one edge of the roll.
struct Sprockets: View {
    var body: some View {
        Canvas { context, size in
            let hole = CGSize(width: 6, height: 8)
            let pitch: CGFloat = 14
            var y: CGFloat = 4
            while y + hole.height <= size.height {
                let rect = CGRect(x: (size.width - hole.width) / 2, y: y, width: hole.width, height: hole.height)
                context.fill(Path(roundedRect: rect, cornerRadius: 1.5), with: .color(.white.opacity(0.13)))
                y += pitch
            }
        }
        .frame(width: 16)
        .accessibilityHidden(true)
    }
}

struct SettingsView: View {
    @Environment(GenerationSession.self) private var session
    @State private var showingDownload = false
    @State private var errorMessage: String?

    var body: some View {
        Form {
            Section("Image generation") {
                LabeledContent("Model", value: ModelOption.supported.name)
                HStack {
                    Button("Download Model…") { showingDownload = true }
                    Button("Show Model Folder") {
                        do { NSWorkspace.shared.activateFileViewerSelecting([try NativeGenerator.defaultModelFolder()]) }
                        catch { errorMessage = error.localizedDescription }
                    }
                }.disabled(session.running)
                Text("Models are stored in ImageVibe’s own folder. Once downloaded, image generation works offline.")
                    .font(.caption).foregroundStyle(.secondary)
                if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
            }
        }
        .formStyle(.grouped).padding().frame(width: 520)
        .sheet(isPresented: $showingDownload) { ModelPicker() }
    }
}
