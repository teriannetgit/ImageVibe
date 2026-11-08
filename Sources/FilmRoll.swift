import AppKit
import ImageIO
import Observation
import UniformTypeIdentifiers

/// One generated image: its PNG sits next to a JSON record of the settings that made it.
nonisolated struct Frame: Codable, Identifiable, Sendable, Equatable {
    let id: UUID
    let request: GenerationRequest
    let seconds: Double
    let created: Date
}

/// Every image the app has made, newest first, kept in Application Support/Generations.
@Observable final class FilmRoll {
    private(set) var frames: [Frame] = []
    let directory: URL

    init(directory: URL) {
        self.directory = directory
        reload()
    }

    static func standard() -> FilmRoll {
        let support = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                    appropriateFor: nil, create: true)) ?? FileManager.default.temporaryDirectory
        return FilmRoll(directory: support.appending(path: "Generations", directoryHint: .isDirectory))
    }

    func imageURL(_ frame: Frame) -> URL { directory.appending(path: "\(frame.id.uuidString).png") }
    private func recordURL(_ frame: Frame) -> URL { directory.appending(path: "\(frame.id.uuidString).json") }

    func reload() {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        frames = files.filter { $0.pathExtension == "json" }
            .compactMap { try? JSONDecoder().decode(Frame.self, from: Data(contentsOf: $0)) }
            .filter { FileManager.default.fileExists(atPath: imageURL($0).path) }
            .sorted { $0.created > $1.created }
    }

    @discardableResult
    func add(_ picture: GeneratedPicture, for request: GenerationRequest) throws -> Frame {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let frame = Frame(id: UUID(), request: request, seconds: picture.seconds, created: .now)
        try picture.png.write(to: imageURL(frame), options: .atomic)
        // The record goes last: reload() only lists frames whose record exists.
        do {
            try JSONEncoder().encode(frame).write(to: recordURL(frame), options: .atomic)
        } catch {
            try? FileManager.default.removeItem(at: imageURL(frame))
            throw error
        }
        frames.insert(frame, at: 0)
        return frame
    }

    /// Moves the frame's files to the Trash, so a mistaken delete can be recovered in Finder.
    func trash(_ frame: Frame) throws {
        var trashedImage: NSURL?
        try FileManager.default.trashItem(at: imageURL(frame), resultingItemURL: &trashedImage)
        do {
            try FileManager.default.trashItem(at: recordURL(frame), resultingItemURL: nil)
        } catch {
            // Keep the frame usable when only half of the deletion succeeds.
            if let trashedImage { try FileManager.default.moveItem(at: trashedImage as URL, to: imageURL(frame)) }
            throw error
        }
        frames.removeAll { $0.id == frame.id }
    }

    /// Opens the frame's PNG in Preview (or the default image viewer if Preview is missing).
    func openInPreview(_ frame: Frame) {
        let url = imageURL(frame)
        if let preview = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Preview") {
            NSWorkspace.shared.open([url], withApplicationAt: preview, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    /// Puts the frame on the clipboard as PNG, plus TIFF for apps that only paste that.
    func copy(_ frame: Frame, to pasteboard: NSPasteboard = .general) throws {
        let png = try Data(contentsOf: imageURL(frame))
        pasteboard.clearContents()
        pasteboard.declareTypes([.png, .tiff], owner: nil)
        pasteboard.setData(png, forType: .png)
        if let tiff = NSImage(data: png)?.tiffRepresentation { pasteboard.setData(tiff, forType: .tiff) }
    }

    func save(_ frame: Frame) throws {
        _ = try save(png: Data(contentsOf: imageURL(frame)), prompt: frame.request.prompt)
    }

    /// Returns false when the user cancels, keeping an unsaved result available.
    func save(png: Data, prompt: String) throws -> Bool {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = Self.fileName(for: prompt)
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        try png.write(to: url, options: .atomic)
        return true
    }

    /// First few words of the prompt, safe for a file name.
    nonisolated static func fileName(for prompt: String) -> String {
        let words = prompt.lowercased().split { !$0.isLetter && !$0.isNumber }.prefix(6)
        return words.isEmpty ? "ImageVibe Image" : words.joined(separator: "-")
    }
}

nonisolated enum Thumbnail {
    /// Downsampled off the main thread so a long roll scrolls smoothly.
    @concurrent static func load(_ url: URL, maxPixels: Int = 480) async -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                       kCGImageSourceCreateThumbnailWithTransform: true,
                       kCGImageSourceThumbnailMaxPixelSize: maxPixels] as CFDictionary
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options)
    }
}
