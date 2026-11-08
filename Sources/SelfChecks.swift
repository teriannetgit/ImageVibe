import AppKit
import ImageIO

enum SelfChecks {
    static func run() throws {
        let request = try GenerationRequest(prompt: "  a teapot\n", width: 512, height: 512, seed: 1)
        precondition(request.prompt == "a teapot" && request.steps == 4 && !request.preciseDecode)
        for prompt in ["", " \n", String(repeating: "x", count: 2_001)] {
            do { _ = try GenerationRequest(prompt: prompt, width: 512, height: 512, seed: 1); preconditionFailure("Invalid prompt accepted") }
            catch StudioError.invalidPrompt { }
        }
        for (width, height) in [(513, 512), (512, 1040), (240, 512), (1000, 512)] {
            do { _ = try GenerationRequest(prompt: "teapot", width: width, height: height, seed: 1); preconditionFailure("Invalid size accepted") }
            catch StudioError.invalidSize { }
        }
        for steps in [0, 9] {
            do { _ = try GenerationRequest(prompt: "teapot", width: 512, height: 512, steps: steps, seed: 1); preconditionFailure("Invalid steps accepted") }
            catch StudioError.invalidSteps { }
        }
        // Every aspect at both sizes must be a request the engine accepts.
        for aspect in Aspect.allCases {
            for edge in [512, 1024] {
                let (width, height) = aspect.size(longEdge: edge)
                _ = try GenerationRequest(prompt: "teapot", width: width, height: height, seed: 1)
            }
        }
        precondition(Aspect.landscape.size(longEdge: 1024) == (1024, 688))
        precondition(Aspect.portrait.size(longEdge: 512) == (336, 512))
        precondition(Aspect.wide.size(longEdge: 1024) == (1024, 576))

        let png = try NativeGenerator.pngData(rgb: Data([255, 0, 0, 0, 255, 0]), width: 2, height: 1)
        guard let source = CGImageSourceCreateWithData(png as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { preconditionFailure("PNG cannot decode") }
        precondition(image.width == 2 && image.height == 1)
        let label = CGImageSourceCopyMetadataAtIndex(source, 0, nil).flatMap {
            CGImageMetadataCopyStringValueWithPath($0, nil, NativeGenerator.digitalSourceTypePath as CFString) as String?
        }
        precondition(label == NativeGenerator.trainedAlgorithmicMedia, "PNG is missing its AI-generated label")
        for (data, width, height) in [(Data(), 1, 1), (Data([1, 2, 3]), 0, 1), (Data([1, 2, 3]), 1025, 1)] {
            do { _ = try NativeGenerator.pngData(rgb: data, width: width, height: height); preconditionFailure("Invalid RGB accepted") }
            catch StudioError.invalidImage { }
        }

        precondition(NativeGenerator.promptWarning(tokenCount: 512) == nil)
        precondition(NativeGenerator.promptWarning(tokenCount: 513) != nil)

        let fixture = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try Data("abc".utf8).write(to: fixture)
        defer { try? FileManager.default.removeItem(at: fixture) }
        let hash = try NativeGenerator.sha256(fixture)
        precondition(hash == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")

        // Film roll: a frame written by one roll is read back, with its settings, by a fresh one.
        let rollFolder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: rollFolder) }
        let roll = FilmRoll(directory: rollFolder)
        let settings = try GenerationRequest(prompt: "a teapot", width: 1024, height: 688, steps: 6, seed: 7, preciseDecode: true)
        let frame = try roll.add(GeneratedPicture(png: png, seconds: 1.5), for: settings)
        let reread = FilmRoll(directory: rollFolder)
        precondition(reread.frames == [frame] && reread.frames[0].request == settings)
        let stored = try Data(contentsOf: reread.imageURL(frame))
        precondition(stored == png)
        // A failed record write must not leave an invisible PNG behind.
        let before = try FileManager.default.contentsOfDirectory(atPath: rollFolder.path).sorted()
        do {
            _ = try roll.add(GeneratedPicture(png: png, seconds: .nan), for: settings)
            preconditionFailure("Non-finite duration should fail JSON encoding")
        } catch is EncodingError { }
        let after = try FileManager.default.contentsOfDirectory(atPath: rollFolder.path).sorted()
        precondition(after == before)
        precondition(roll.frames == [frame])

        // Failure to trash the PNG must leave its record and the visible frame intact.
        try FileManager.default.removeItem(at: roll.imageURL(frame))
        do {
            try roll.trash(frame)
            preconditionFailure("Trashing a missing PNG should fail")
        } catch { }
        precondition(roll.frames == [frame])
        precondition(FileManager.default.fileExists(atPath: rollFolder.appending(path: "\(frame.id.uuidString).json").path))
        try png.write(to: roll.imageURL(frame))

        let board = NSPasteboard(name: NSPasteboard.Name("ImageVibe.selfcheck"))
        defer { board.releaseGlobally() }
        try reread.copy(frame, to: board)
        precondition(board.data(forType: .png) == png && board.data(forType: .tiff) != nil, "Copy Image did not put the PNG on the clipboard")

        precondition(FilmRoll.fileName(for: "A blue ceramic teapot, on a wooden table!") == "a-blue-ceramic-teapot-on-a")
        precondition(FilmRoll.fileName(for: "  ¿? ") == "ImageVibe Image")
        print("SELF CHECKS PASSED: request bounds, aspect sizes, PNG roundtrip and AI label, SHA-256, film roll storage, copy to clipboard, file names")
    }
}
