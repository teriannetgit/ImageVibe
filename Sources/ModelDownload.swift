import Foundation
import SwiftUI

nonisolated struct ModelFile: Sendable {
    let path: String
    let sha256: String
    let size: Int64
}

nonisolated struct ModelOption: Sendable, Identifiable {
    let id: String   // Hugging Face repository
    let name: String
    let detail: String
    let revision: String
    /// What the engine reads.
    let files: [ModelFile]
    /// The model's own license terms, kept beside the weights (Apache-2.0 §4).
    var notices: [ModelFile] = []

    var download: [ModelFile] { files + notices }
    var totalSize: Int64 { download.reduce(0) { $0 + $1.size } }

    func url(for file: ModelFile) -> URL {
        URL(string: "https://huggingface.co/\(id)/resolve/\(revision)/\(file.path)")!
    }

    // One entry; the pinned engine only runs the ternary 2-bit layout (PrismML's 1-bit model would crash it).
    // Add rows here when the engine supports more.
    static let all = [
        ModelOption(
            id: "prism-ml/bonsai-image-ternary-4B-mlx-2bit", name: "Bonsai Image 4B · Ternary",
            detail: "PrismML’s quality-focused model for Apple silicon. Apache-2.0.",
            revision: "2c24c81b934a658ba5590cf39088ba929985b4a8",
            files: [
                ModelFile(path: "text_encoder-mlx-4bit/model.safetensors",
                          sha256: "e240c0bdc0ebb0681bf0da0f98d9719fd6ebe269a3633f81542c13e81345651d", size: 2_263_022_529),
                ModelFile(path: "transformer-packed-mflux/diffusion_pytorch_model.safetensors",
                          sha256: "b21737bdf02690b7d662907781c4dc8b8bf22a2c98b823b1ca3336f48371a84f", size: 1_425_271_472),
                ModelFile(path: "tokenizer/tokenizer.json",
                          sha256: "aeb13307a71acd8fe81861d94ad54ab689df773318809eed3cbe794b4492dae4", size: 11_422_654),
                ModelFile(path: "tokenizer/tokenizer_config.json",
                          sha256: "443bfa629eb16387a12edbf92a76f6a6f10b2af3b53d87ba1550adfcf45f7fa0", size: 5_404)
            ],
            notices: [
                ModelFile(path: "LICENSE",
                          sha256: "69849221bfb90053de2134ef5e6d540287b4b98062326492f1f96f5da685524b", size: 10_174),
                ModelFile(path: "NOTICE.md",
                          sha256: "bbefa4a26b836efc040c1a0f155a425d1d833eae1b2534ffc414b1eada3cd922", size: 623)
            ])
    ]
    static let supported = all[0]
}

nonisolated enum ModelDownload {
    /// Downloads each missing or damaged file, checks its SHA-256, then moves it into `folder`. Files already correct are kept.
    @concurrent static func install(_ option: ModelOption, into folder: URL,
                                    progress: @escaping @Sendable (Double) -> Void) async throws {
        let total = Double(option.totalSize)
        var done: Int64 = 0
        for file in option.download {
            let destination = folder.appending(path: file.path)
            if FileManager.default.fileExists(atPath: destination.path),
               try NativeGenerator.sha256(destination) == file.sha256 {
                done += file.size
                progress(Double(done) / total)
                continue
            }
            let base = done
            let temporary = try await FileDownload.fetch(option.url(for: file), path: file.path) { received in
                progress(Double(base + received) / total)
            }
            defer { try? FileManager.default.removeItem(at: temporary) }
            guard try NativeGenerator.sha256(temporary) == file.sha256 else { throw StudioError.wrongWeights(file.path) }
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
            try FileManager.default.moveItem(at: temporary, to: destination)
            done += file.size
            progress(Double(done) / total)
        }
    }
}

/// Downloads one file through a session delegate, which receives byte counts as data arrives.
/// (The async `URLSession.download(from:delegate:)` never calls a per-task delegate's progress methods.)
nonisolated private final class FileDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    // Touched only on the session's serial delegate queue, after `fetch` sets them before resuming the task.
    private var continuation: CheckedContinuation<URL, Error>?
    private var kept: URL?
    private var last: Int64 = 0
    private let path: String
    private let report: @Sendable (Int64) -> Void

    private init(path: String, report: @escaping @Sendable (Int64) -> Void) {
        self.path = path
        self.report = report
    }

    /// Returns a temporary file the caller owns; progress is reported about every 4 MB.
    static func fetch(_ url: URL, path: String, report: @escaping @Sendable (Int64) -> Void) async throws -> URL {
        let delegate = FileDownload(path: path, report: report)
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let task = session.downloadTask(with: url)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                delegate.continuation = continuation
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesWritten - last >= 4_000_000 else { return }
        last = totalBytesWritten
        report(totalBytesWritten)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // `location` is deleted when this returns, so move it somewhere that lasts.
        guard (downloadTask.response as? HTTPURLResponse)?.statusCode == 200 else { return }
        let destination = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        if (try? FileManager.default.moveItem(at: location, to: destination)) != nil { kept = destination }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            continuation?.resume(throwing: (error as? URLError)?.code == .cancelled ? CancellationError() : error)
        } else if let kept {
            continuation?.resume(returning: kept)
        } else {
            continuation?.resume(throwing: StudioError.downloadFailed(path))
        }
        continuation = nil
    }
}

struct ModelPicker: View {
    @Environment(\.dismiss) private var dismiss
    @State private var selection = ModelOption.supported.id
    @State private var fraction: Double?
    @State private var error: String?
    @State private var task: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Download a Bonsai model").font(.title2.bold())
            Text("ImageVibe needs a model to make images. Choose one to download. It’s saved in the app’s own folder, checked against its published hashes, and then works offline.")
                .fixedSize(horizontal: false, vertical: true)
            Picker("Model", selection: $selection) {
                ForEach(ModelOption.all) { option in
                    VStack(alignment: .leading) {
                        Text(option.name)
                        Text("\(option.detail) \(ByteCountFormatter.string(fromByteCount: option.totalSize, countStyle: .file))")
                            .font(.caption).foregroundStyle(.secondary)
                    }.tag(option.id)
                }
            }
            .pickerStyle(.radioGroup).labelsHidden()
            .disabled(fraction != nil)
            if let fraction { ProgressView("Downloading…", value: fraction) }
            if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                Spacer()
                Button("Cancel") { task?.cancel(); dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Download") { start() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(fraction != nil)
            }
        }
        .padding(24)
        .frame(width: 480)
        .interactiveDismissDisabled()
    }

    private func start() {
        guard let option = ModelOption.all.first(where: { $0.id == selection }) else { return }
        fraction = 0
        error = nil
        task = Task {
            do {
                try await ModelDownload.install(option, into: try NativeGenerator.defaultModelFolder()) { value in
                    Task { @MainActor in if fraction != nil { fraction = value } }
                }
                dismiss()
            } catch is CancellationError {
            } catch {
                self.error = error.localizedDescription
                fraction = nil
            }
        }
    }
}
