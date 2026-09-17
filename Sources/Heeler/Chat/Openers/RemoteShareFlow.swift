import SwiftUI
import UniformTypeIdentifiers

// SPDX-License-Identifier: Apache-2.0
//
// The v1 "everything else" for tapped remote paths: download the file
// silently, then hand it to the system share sheet / document picker
// export. Editor hand-off (the `EditorTransfer` push-back) is v2; this
// download half deliberately matches that contract's shape so v2 is
// additive.

/// One downloaded remote file.
struct DownloadedRemoteFile: Equatable, Sendable {
    let url: URL
    let byteCount: Int
}

/// The `EditorTransfer` contract's v1 conformance: silent whole-file
/// download to a per-pane temp container. The v2 `upload` half throws
/// until the watch-for-change push-back ships — no v1 caller exists.
@MainActor
final class RemoteDownloadTransfer: EditorTransfer {
    let intent: EditorTransferIntent

    private let fetch: RemoteFileFetcher
    private let directory: URL

    /// - Parameters:
    ///   - fetch: silent whole-file remote read (Transport.readTranscriptFile
    ///     in production; in-memory closures in tests).
    ///   - directory: where downloads land; a fresh subdirectory per
    ///     download, wiped on `cleanup()`.
    ///   - intent: `.view` for v1 (the share flow); `.edit` arrives with v2.
    init(
        fetch: @escaping RemoteFileFetcher,
        directory: URL,
        intent: EditorTransferIntent = .view
    ) {
        self.fetch = fetch
        self.directory = directory
        self.intent = intent
    }

    func download(
        _ path: String, progress: (@Sendable (Int64) -> Void)? = nil
    ) async throws -> URL {
        let data = try await fetch(path)
        guard OpenRouter.allowsSilentFetch(byteCount: data.count) else {
            throw RemoteDownloadError.tooLarge
        }
        let container = directory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(
            at: container, withIntermediateDirectories: true)
        let destination = container.appending(
            path: (path as NSString).lastPathComponent)
        try data.write(to: destination, options: .atomic)
        progress?(Int64(data.count))
        return destination
    }

    /// v2's watch-for-change push-back; deliberately unimplemented in v1.
    func upload(_ localURL: URL) async throws {
        throw RemoteDownloadError.editPushbackUnavailable
    }

    /// Wipes every download this transfer created.
    func cleanup() {
        try? FileManager.default.removeItem(at: directory)
    }
}

enum RemoteDownloadError: Error, Equatable {
    case tooLarge
    case editPushbackUnavailable
}

/// Sheet for one tapped remote path that is not markdown: download it
/// silently, then offer Share (system share sheet) and Save to Files
/// (document-picker export). The download is invisible when it succeeds —
/// the sheet turns straight into the result.
struct RemoteShareFlow: View {
    let target: RemoteShareTarget
    /// The silent remote-file fetch, injected (same seam the markdown
    /// viewer uses).
    var fetch: RemoteFileFetcher
    @ObservedObject var router: OpenRouterCore

    @State private var downloaded: DownloadedRemoteFile?
    @State private var failureMessage: String?
    @State private var showShareSheet = false
    @State private var showDocumentExporter = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                if let downloaded {
                    Image(systemName: "doc.fill")
                        .font(.system(size: 36))
                        .foregroundStyle(.tint)
                    Text(downloaded.url.lastPathComponent)
                        .font(.headline.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("\(downloaded.byteCount) bytes · \(target.path)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    HStack(spacing: 12) {
                        Button {
                            showShareSheet = true
                        } label: {
                            Label("Share", systemImage: "square.and.arrow.up")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        Button {
                            showDocumentExporter = true
                        } label: {
                            Label("Save to Files", systemImage: "folder")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding(.horizontal, 24)
                } else if let failureMessage {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 36))
                        .foregroundStyle(.orange)
                    Text(failureMessage)
                        .font(.subheadline)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                } else {
                    Image(systemName: "arrow.down.doc")
                        .font(.system(size: 36))
                        .foregroundStyle(.tint)
                    Text(target.path)
                        .font(.subheadline)
                        .lineLimit(2)
                        .truncationMode(.middle)
                    Text("Fetching the file from the host…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.top, 32)
            .navigationTitle("Remote File")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        router.dismissShareTarget()
                    }
                }
            }
            .task { await download() }
            .sheet(isPresented: $showShareSheet) {
                if let downloaded {
                    ShareSheet(items: [downloaded.url])
                }
            }
            .fileExporter(
                isPresented: $showDocumentExporter,
                document: downloaded.map { DownloadedFileDocument(fileURL: $0.url) },
                contentType: UTType.data
            ) { _ in }
        }
        .interactiveDismissDisabled(failureMessage == nil && downloaded == nil)
    }

    /// The silent fetch: no progress UI — a failure swaps in the message.
    private func download() async {
        do {
            let data = try await fetch(target.path)
            guard OpenRouter.allowsSilentFetch(byteCount: data.count) else {
                throw RemoteDownloadError.tooLarge
            }
            let destination = try writeLocally(data)
            downloaded = DownloadedRemoteFile(
                url: destination, byteCount: data.count)
        } catch RemoteDownloadError.tooLarge {
            failureMessage = "This file is over the silent-transfer limit (10 MB)."
        } catch is CancellationError {
            return
        } catch {
            failureMessage =
                "Couldn't read \(target.path) on the host. It may be missing."
        }
    }

    /// Writes the fetched bytes to a per-share temp file (not the
    /// `RemoteDownloadTransfer` container — this flow's lifetime ends with
    /// the sheet, and the share/export targets take copies).
    private func writeLocally(_ data: Data) throws -> URL {
        let container = FileManager.default.temporaryDirectory
            .appending(path: "ChatOpeners")
        try FileManager.default.createDirectory(
            at: container, withIntermediateDirectories: true)
        let destination = container.appending(
            path: (target.path as NSString).lastPathComponent)
        try data.write(to: destination, options: .atomic)
        return destination
    }
}

/// The minimal `Transferable` document `fileExporter` needs for a
/// downloaded local file.
struct DownloadedFileDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.data] }

    let fileURL: URL

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    init(configuration: ReadConfiguration) throws {
        fileURL = URL(fileURLWithPath: "")
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        guard let data = try? Data(contentsOf: fileURL) else {
            throw CocoaError(.fileNoSuchFile)
        }
        return FileWrapper(regularFileWithContents: data)
    }
}

/// The system share sheet over whatever was opened (URL, local file, text).
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(
        _ controller: UIActivityViewController, context: Context
    ) {}
}
