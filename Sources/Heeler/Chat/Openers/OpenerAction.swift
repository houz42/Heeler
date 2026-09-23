import Foundation

// SPDX-License-Identifier: Apache-2.0
//
// The opener seams' shared types: what a routing decision resolves to, and
// the v2 editor hand-off contract. OpenRouter's routing is pure over these
// values; the views interpret them.

/// Where a routing decision sends a target. `OpenRouter.route` is pure —
/// tests pin it against recording stubs; `OpenRouter` interprets the action.
enum OpenerAction: Equatable, Sendable {
    /// Hand the URL to the embedded SFSafariViewController.
    ///
    /// `allowed`: the domain has an explicit allow decision persisted in
    /// `dev.houz42.heeler.openers`; `nil`: no decision exists yet, so the
    /// presentation asks the user first.
    case browse(url: URL, allowed: Bool?)
    /// A loopback/localhost link: presented as the honest "Local address
    /// unavailable" notice (the address belongs to the originating
    /// agent host, not the phone; no forwarding exists in v3).
    case localAddress(LocalAddressNotice)
    /// A remote absolute path ending `.md` fetched silently and opened in
    /// the internal markdown viewer.
    case viewMarkdown(path: String)
    /// A remote file to download first, then hand to the share / export
    /// flow (v1's "everything else" for remote paths).
    case shareFile(path: String)
}

/// Editor hand-off contract (v2 per plan; deferred). One transfer takes a
/// remote file to local editor ownership: download for local editing, then
/// upload the changed file back. The download half has a real v1
/// conformance (`RemoteDownloadTransfer`); the upload half ships with v2's
/// watch-for-change push-back, additively.
@MainActor
protocol EditorTransfer: AnyObject {
    /// The editor intent for a transfer, so routing can branch on it.
    var intent: EditorTransferIntent { get }

    /// Downloads `path` to a local container URL. `progress` is optional
    /// and only surfaced for large files; small transfers are silent.
    func download(
        _ path: String, progress: (@Sendable (Int64) -> Void)?
    ) async throws -> URL

    /// Uploads the working copy back to its remote origin (v2).
    func upload(_ localURL: URL) async throws
}

enum EditorTransferIntent: Sendable, Equatable {
    /// Silent fetch for read-only viewing and export (v1's paths).
    case view
    /// Download then edit, with the push-back upload to follow (v2).
    case edit
}
