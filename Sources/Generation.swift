import Foundation
import os
import BonsaiEngine
import CryptoKit
import ImageIO
import Observation
import UniformTypeIdentifiers

nonisolated enum StudioError: LocalizedError {
    case invalidPrompt, invalidSize, invalidSteps, busy, missingModels(String), invalidImage, wrongWeights(String), downloadFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidPrompt: "Enter a prompt of at most 2,000 characters."
        case .invalidSize: "Width and height must be multiples of 16 between 256 and 1,024 pixels."
        case .invalidSteps: "Choose between 1 and 8 steps."
        case .busy: "An image is already being generated."
        case .missingModels(let file): "Missing model file: \(file). Download the Bonsai model first."
        case .invalidImage: "The engine did not return a usable image."
        case .wrongWeights(let file): "A model file doesn’t match the verified Bonsai ternary weights: \(file)."
        case .downloadFailed(let file): "Couldn’t download \(file). Check your internet connection and try again."
        }
    }
}

/// Everything the engine takes. Stored with each film-roll frame so a result can be reproduced.
nonisolated struct GenerationRequest: Sendable, Codable, Equatable {
    let prompt: String
    let width: Int
    let height: Int
    let steps: Int
    let seed: UInt64
    /// Decodes in float32 instead of bfloat16: slightly finer detail, more memory.
    let preciseDecode: Bool

    static let sizes = 256...1024
    static let stepRange = 1...8
    static let defaultSteps = 4

    init(prompt: String, width: Int, height: Int, steps: Int = defaultSteps, seed: UInt64,
         preciseDecode: Bool = false) throws {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 2_000 else { throw StudioError.invalidPrompt }
        guard [width, height].allSatisfy({ Self.sizes.contains($0) && $0 % 16 == 0 }) else { throw StudioError.invalidSize }
        guard Self.stepRange.contains(steps) else { throw StudioError.invalidSteps }
        self.prompt = trimmed
        self.width = width
        self.height = height
        self.steps = steps
        self.seed = seed
        self.preciseDecode = preciseDecode
    }
}

/// Shape choices offered in the composer; sizes snap to the engine's 16-pixel grid.
enum Aspect: String, CaseIterable, Identifiable {
    case square, landscape, portrait, wide

    var id: Self { self }
    var label: String {
        switch self {
        case .square: "Square"
        case .landscape: "Landscape 3:2"
        case .portrait: "Portrait 2:3"
        case .wide: "Wide 16:9"
        }
    }
    var ratio: String {
        switch self {
        case .square: "1:1"
        case .landscape: "3:2"
        case .portrait: "2:3"
        case .wide: "16:9"
        }
    }

    nonisolated func size(longEdge: Int) -> (width: Int, height: Int) {
        let (w, h) = switch self {
        case .square: (1, 1)
        case .landscape: (3, 2)
        case .portrait: (2, 3)
        case .wide: (16, 9)
        }
        let short = Int((Double(longEdge * min(w, h)) / Double(max(w, h)) / 16).rounded()) * 16
        return w >= h ? (longEdge, short) : (short, longEdge)
    }
}

nonisolated struct GeneratedPicture: Sendable {
    let png: Data
    let seconds: Double
}

nonisolated enum NativeGenerator {
    // One synchronous job keeps MLX model creation and use on the same worker thread.
    @concurrent static func generate(
        _ request: GenerationRequest, vaeURL: URL,
        warning: @escaping @Sendable (String) -> Void = { _ in },
        progress: @escaping @Sendable (String, Double) -> Void
    ) async throws -> GeneratedPicture {
        try Task.checkCancellation()
        return try generate(request, in: try defaultModelFolder(), vaeURL: vaeURL, warning: warning, progress: progress)
    }

    /// The app's model folder inside its sandbox container.
    static func defaultModelFolder() throws -> URL {
        let folder = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                 appropriateFor: nil, create: true)
            .appending(path: "Models/bonsai-image-4B-ternary-mlx", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    static func defaultModelMissing() -> Bool {
        guard let folder = try? defaultModelFolder() else { return true }
        // Includes the license files, so an install from before they were downloaded fetches them.
        return ModelOption.supported.download.contains { !FileManager.default.fileExists(atPath: folder.appending(path: $0.path).path) }
    }

    private static func generate(
        _ request: GenerationRequest, in folder: URL, vaeURL: URL,
        warning: @escaping @Sendable (String) -> Void,
        progress: @escaping @Sendable (String, Double) -> Void
    ) throws -> GeneratedPicture {
        // The candidate engine force-unwraps tensor keys; refuse unverified files before it can trap.
        // Hashing ~4 GB takes seconds, so only re-hash when a file's size or modification date changes.
        var fingerprint: [String] = []
        let required = ModelOption.supported.files
        for model in required {
            let path = model.path
            let file = folder.appending(path: path)
            guard FileManager.default.isReadableFile(atPath: file.path) else {
                throw StudioError.missingModels(path)
            }
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            fingerprint.append("\(folder.path)/\(path):\(attributes[.size] ?? 0):\(modified)")
        }
        let verifiedKey = "image.verifiedModels"
        if UserDefaults.standard.stringArray(forKey: verifiedKey) != fingerprint {
            progress("Checking model files", 0)
            for model in required {
                guard try sha256(folder.appending(path: model.path)) == model.sha256 else { throw StudioError.wrongWeights(model.path) }
            }
            UserDefaults.standard.set(fingerprint, forKey: verifiedKey)
        }
        guard FileManager.default.isReadableFile(atPath: vaeURL.path) else {
            throw StudioError.missingModels("bundled vae.safetensors")
        }
        let tokenizer = try QwenTokenizer.load(dir: folder.appending(path: "tokenizer"))
        let count = QwenTokenizer.promptIds(tokenizer, prompt: request.prompt).count
        if let message = promptWarning(tokenCount: count) { warning(message) }
        let start = ContinuousClock.now
        let output = try autoreleasepool {
            let pipeline = BonsaiPipeline(modelDir: folder.path, vaePath: vaeURL.path)
            return try pipeline.generate(prompt: request.prompt, height: request.height, width: request.width,
                                         steps: request.steps, seed: request.seed,
                                         vaeFp32: request.preciseDecode) { phase, fraction in
                progress(phase.rawValue.capitalized, fraction)
            }
        }
        // shortcut: upstream cannot interrupt a GPU run; cancellation discards its result until the engine gains checks.
        try Task.checkCancellation()
        guard output.width == request.width, output.height == request.height else { throw StudioError.invalidImage }
        let png = try pngData(rgb: output.rgb, width: output.width, height: output.height)
        let elapsed = start.duration(to: .now)
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        return GeneratedPicture(png: png, seconds: seconds)
    }

    static func promptWarning(tokenCount: Int) -> String? {
        guard tokenCount > Qwen3Encoder.maxLen else { return nil }
        return "This prompt exceeds the model’s limit. Only the first \(Qwen3Encoder.maxLen) tokens, including formatting, are used; later instructions are ignored. Shorten the prompt for your next image."
    }

    static func sha256(_ url: URL) throws -> String {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var hash = SHA256()
        while let chunk = try file.read(upToCount: 4 * 1024 * 1024), !chunk.isEmpty {
            try Task.checkCancellation()
            hash.update(data: chunk)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func pngData(rgb: Data, width: Int, height: Int) throws -> Data {
        guard width > 0, height > 0, width <= 1024, height <= 1024,
              rgb.count == width * height * 3,
              let provider = CGDataProvider(data: rgb as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 24,
                                  bytesPerRow: width * 3, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { throw StudioError.invalidImage }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)
        else { throw StudioError.invalidImage }
        CGImageDestinationAddImageAndMetadata(destination, image, aiMetadata(), nil)
        guard CGImageDestinationFinalize(destination) else { throw StudioError.invalidImage }
        return data as Data
    }

    static let digitalSourceTypePath = "Iptc4xmpExt:DigitalSourceType"
    static let trainedAlgorithmicMedia = "http://cv.iptc.org/newscodes/digitalsourcetype/trainedAlgorithmicMedia"

    /// Marks the image as AI-generated in XMP that software can read (IPTC digital source type),
    /// the machine-readable label EU AI Act Article 50(2) asks for.
    // XMP label only; add signed C2PA content credentials if a store or law requires provenance signing.
    static func aiMetadata() -> CGImageMetadata {
        let metadata = CGImageMetadataCreateMutable()
        CGImageMetadataRegisterNamespaceForPrefix(metadata, "http://iptc.org/std/Iptc4xmpExt/2008-02-29/" as CFString,
                                                  "Iptc4xmpExt" as CFString, nil)
        CGImageMetadataSetValueWithPath(metadata, nil, digitalSourceTypePath as CFString, trainedAlgorithmicMedia as CFString)
        CGImageMetadataSetValueWithPath(metadata, nil, "xmp:CreatorTool" as CFString,
                                        "ImageVibe, using Bonsai Image 4B by Prism ML" as CFString)
        return metadata
    }
}

@Observable final class GenerationSession {
    var running = false
    var phase = "Ready"
    var fraction = 0.0
    /// The request being generated, so the film roll can show a developing frame of the right shape.
    var pending: GenerationRequest?
    var error: String?
    var warning: String?

    func generate(_ request: GenerationRequest) async throws -> GeneratedPicture {
        guard !running else { throw StudioError.busy }
        guard let vae = Bundle.main.url(forResource: "vae", withExtension: "safetensors") else {
            throw StudioError.missingModels("bundled vae.safetensors")
        }
        running = true
        pending = request
        phase = "Loading"
        fraction = 0
        error = nil
        warning = nil
        defer { running = false; pending = nil; phase = "Ready" }
        return try await NativeGenerator.generate(request, vaeURL: vae, warning: { [weak self] message in
            Task { @MainActor in self?.warning = message }
        }) { [weak self] phase, fraction in
            Task { @MainActor in
                // Hops can land after the job ends; don't let a late one overwrite "Ready".
                guard self?.running == true else { return }
                self?.phase = phase
                self?.fraction = fraction
            }
        }
    }

    func validate() async {
        do {
            let directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                        appropriateFor: nil, create: true).appending(path: "BonsaiValidation")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            // Exercises download, redirect, checksum, move and progress with the 11 MB tokenizer.
            let small = ModelOption.supported.files.first { $0.path == "tokenizer/tokenizer.json" }!
            let probe = ModelOption(id: ModelOption.supported.id, name: "probe", detail: "",
                                    revision: ModelOption.supported.revision, files: [small])
            let probeFolder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: probeFolder) }
            let reported = OSAllocatedUnfairLock(initialState: [Double]())
            try await ModelDownload.install(probe, into: probeFolder) { value in
                reported.withLock { $0.append(value) }
            }
            guard try NativeGenerator.sha256(probeFolder.appending(path: small.path)) == small.sha256 else {
                throw StudioError.wrongWeights(small.path)
            }
            let values = reported.withLock { $0 }
            guard values.contains(where: { $0 > 0 && $0 < 1 }), values.last == 1 else {
                throw StudioError.downloadFailed("progress (reported \(values))")
            }
            FileHandle.standardOutput.write(Data("Model download check passed: progress \(values.map { Int($0 * 100) })%\n".utf8))
            let prompts = ["A blue ceramic teapot on a wooden table, soft morning light, photorealistic",
                           "A red sailboat on a calm lake with snowy mountains, photorealistic"]
            var hashes: [String] = []
            var records: [[String: Any]] = []
            for (index, prompt) in prompts.enumerated() {
                let result = try await generate(GenerationRequest(prompt: prompt, width: 512, height: 512, seed: 42))
                let hash = SHA256.hash(data: result.png).map { String(format: "%02x", $0) }.joined()
                hashes.append(hash)
                let name = index == 0 ? "teapot.png" : "sailboat.png"
                try result.png.write(to: directory.appending(path: name), options: .atomic)
                records.append(["prompt": prompt, "size": 512, "seconds": result.seconds, "sha256": hash])
            }
            guard hashes[0] != hashes[1] else { throw StudioError.invalidImage }
            let large = try await generate(GenerationRequest(prompt: prompts[0], width: 1024, height: 1024, seed: 42))
            try large.png.write(to: directory.appending(path: "teapot-1024.png"), options: .atomic)
            records.append(["prompt": prompts[0], "size": 1024, "seconds": large.seconds])
            let data = try JSONSerialization.data(withJSONObject: records, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: directory.appending(path: "results.json"), options: .atomic)
            FileHandle.standardOutput.write(Data("NATIVE VALIDATION PASSED: \(directory.path)\n".utf8))
            exit(0)
        } catch {
            FileHandle.standardOutput.write(Data("NATIVE VALIDATION FAILED: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }
}
