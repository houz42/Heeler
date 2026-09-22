import CryptoKit
import Foundation

/// One broker package this build can install, already verified against
/// its bundled checksums.json.
struct MeadowPackage: Sendable, Equatable {
    let version: String
    let sha256: String
    let prepared: PreparedFile

    init(version: String, sha256: String, prepared: PreparedFile) {
        self.version = version
        self.sha256 = sha256
        self.prepared = prepared
    }
}

/// Supplies the broker package for a Host platform. Production reads the
/// app bundle's Meadow/ folder reference (artifacts + checksums.json +
/// manifest.json, produced by the runtime side); tests inject scripted
/// sources.
protocol MeadowPackageSource: Sendable {
    /// The package for `platform`, verified against the bundled
    /// checksums.json; nil when this build carries no artifact for it.
    func package(for platform: RemoteHostPlatform?) async throws -> MeadowPackage?
}

/// The bundled source: Meadow/ ships as a folder reference, so the
/// files stay under `Meadow/` in the bundle.
struct BundledMeadowPackageSource: MeadowPackageSource {
    struct SourceError: Error, Equatable {
        let message: String
    }

    func package(for platform: RemoteHostPlatform?) async throws -> MeadowPackage? {
        guard let platform else { return nil }
        let osMarker: String
        switch platform {
        case .linux: osMarker = "linux"
        case .macOS: osMarker = "darwin"
        }
        guard let meadowDir = Bundle.main.url(
            forResource: "Meadow", withExtension: nil)
        else {
            throw SourceError(message: "The bundled Meadow package folder is missing.")
        }
        guard let manifestData = try? Data(
            contentsOf: meadowDir.appendingPathComponent("manifest.json")),
            let manifest = try? JSONDecoder().decode(
                MeadowManifest.self, from: manifestData)
        else {
            throw SourceError(message: "The bundled Meadow manifest is unreadable.")
        }
        // Pick the artifact for the platform; arch is arm64 for this
        // build's devices (x64 hosts are served by future artifacts).
        guard let entry = manifest.artifacts.first(where: {
            $0.key.contains("-\(osMarker)-") && $0.key.contains("-arm64")
        }) else {
            return nil
        }
        let artifactURL = meadowDir.appendingPathComponent(entry.key)
        guard let bytes = try? Data(contentsOf: artifactURL) else {
            throw SourceError(message: "The bundled broker artifact is unreadable.")
        }
        // Verify against the bundled checksums.json — the same gate the
        // remote install re-verifies after staging.
        guard Self.sha256Hex(bytes) == entry.value.lowercased() else {
            throw SourceError(message: "The bundled broker artifact failed its checksum.")
        }
        // Copy into prepared-file storage: staging owns the temp copy's
        // lifecycle (remove-after-install).
        let preparedURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("meadow-pkg-\(UUID().uuidString).targz")
        do {
            try bytes.write(to: preparedURL)
        } catch {
            throw SourceError(message: "Could not stage the broker package locally.")
        }
        return MeadowPackage(
            version: manifest.version,
            sha256: entry.value.lowercased(),
            prepared: PreparedFile(
                fileURL: preparedURL,
                fileExtension: "targz",
                byteCount: Int64(bytes.count)))
    }

    private struct MeadowManifest: Codable {
        let version: String
        let artifacts: [String: String]
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
