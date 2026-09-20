import Foundation

/// The remote Host's operating system, resolved by the inspect probe.
/// Everything downstream — directory layout, service system, checksum
/// utility — is keyed off it.
enum RemoteHostPlatform: String, Sendable, Equatable {
    case linux
    case macOS

    init(marker: String) {
        switch marker {
        case "darwin": self = .macOS
        default: self = .linux
        }
    }

    var displayName: String {
        switch self {
        case .linux: "Linux"
        case .macOS: "macOS"
        }
    }
}

/// The complete host-side footprint of the chat broker, per platform:
/// every provisioning command is derived from one instance, so the
/// development-testing rule (disposable dirs + service names) is a matter
/// of swapping the instance, and a layout change is one place.
///
/// Linux layout (XDG):
/// - install: `<dataRoot>/versions/<version>/`, active version in the
///   `current` marker FILE (atomic via tmp+rename; a symlink swap needs
///   GNU-only `mv -T` and would corrupt on BSD mv).
/// - config: `~/.config/heeler-chat/` (`broker.env`, `adapter/`)
/// - state:  `~/.local/state/heeler-chat/` (socket, logs)
///
/// macOS layout (no XDG):
/// - `~/Library/Application Support/HeelerChat/` — versions/current/logs
/// - socket in the same tree (dir 0700)
struct BrokerProvisioningLayout: Sendable, Equatable {
    /// Fixed socket name; chat connects direct-streamlocal to this path.
    static let socketName = "broker.sock"
    /// The ask-wrapper opt-in flag; OFF (absent) by default, per the
    /// adapter-config contract.
    static let askWrapperEnvironmentKey = "HEELER_CHAT_ASK_WRAPPER"
    /// Minimum Node major version the broker package declares.
    static let minimumNodeMajorVersion = 22

    let platform: RemoteHostPlatform
    /// Absolute install root that holds `versions/` and `current`.
    let dataRoot: String
    /// Absolute config dir (`broker.env`, `adapter/`).
    let configRoot: String
    /// Absolute state dir (socket, logs).
    let stateRoot: String
    /// Service name: `heeler-chat-broker` (systemd) or
    /// `com.heeler.chat.broker` (launchd).
    let serviceName: String

    /// The production layout for one platform.
    static func standard(platform: RemoteHostPlatform, homeDirectory: String) -> BrokerProvisioningLayout {
        switch platform {
        case .linux:
            return BrokerProvisioningLayout(
                platform: platform,
                dataRoot: "\(homeDirectory)/.local/share/heeler-chat",
                configRoot: "\(homeDirectory)/.config/heeler-chat",
                stateRoot: "\(homeDirectory)/.local/state/heeler-chat",
                serviceName: "heeler-chat-broker")
        case .macOS:
            return BrokerProvisioningLayout(
                platform: platform,
                dataRoot: "\(homeDirectory)/Library/Application Support/HeelerChat",
                configRoot: "\(homeDirectory)/Library/Application Support/HeelerChat/config",
                stateRoot: "\(homeDirectory)/Library/Application Support/HeelerChat",
                serviceName: "com.heeler.chat.broker")
        }
    }

    /// Disposable development layout: a test root under /tmp and a
    /// `heeler-chat-test-` service name. Production code never constructs
    /// this; tests use it to honor "never install into the user's normal
    /// remote setup during development".
    static func development(platform: RemoteHostPlatform, root: String, suffix: String) -> BrokerProvisioningLayout {
        let base = "\(root)/heeler-chat-test-\(suffix)"
        return BrokerProvisioningLayout(
            platform: platform,
            dataRoot: "\(base)/data",
            configRoot: "\(base)/config",
            stateRoot: "\(base)/state",
            serviceName: "heeler-chat-test-\(suffix)")
    }

    var versionsDirectory: String { "\(dataRoot)/versions" }
    /// Path of the atomic `current` marker FILE (contains the active
    /// version string, one line).
    var currentVersionMarkerPath: String { "\(dataRoot)/current" }
    var logsDirectory: String { "\(stateRoot)/logs" }
    var socketPath: String { "\(stateRoot)/\(Self.socketName)" }
    var brokerEnvironmentFilePath: String { "\(configRoot)/broker.env" }
    var adapterDirectory: String { "\(configRoot)/adapter" }

    /// Where the active install's broker entrypoint lives, given the
    /// version the `current` marker names.
    func brokerExecutablePath(activeVersion: String) -> String {
        "\(versionsDirectory)/\(activeVersion)/broker/bin/broker"
    }

    /// The systemd/launchd unit's file path on the Host.
    var unitFilePath: String {
        switch platform {
        case .linux: "\(configRoot)/../systemd/user/\(serviceName).service"
        case .macOS: "~/Library/LaunchAgents/\(serviceName).plist"
        }
    }

    // MARK: - Command builders

    /// Single-quote `value` for a POSIX shell. Refuses (nil) anything with
    /// a quote, backslash, or control character — the conservative subset
    /// shared with `RemoteShellPath`.
    private static func quoted(_ value: String) -> String? {
        guard value.unicodeScalars.allSatisfy({ scalar in
            scalar.value >= 0x20 && scalar.value != 0x7F
                && scalar.value != 0x27 && scalar.value != 0x5C
        }) else { return nil }
        return "'\(value)'"
    }

    /// `printf '%s\n' version > current.tmp && mv current.tmp current` —
    /// the atomic swap. `mv` of a regular file over an existing regular
    /// file is rename(2), atomic on Linux and macOS.
    func swapCurrentMarkerCommand(version: String) throws -> String {
        guard let quotedVersion = Self.quoted(version) else {
            throw BrokerProvisioningError.layoutPathUnsafe
        }
        return "printf '%s\\n' \(quotedVersion) > \(currentVersionMarkerPath).tmp "
            + "&& mv \(currentVersionMarkerPath).tmp \(currentVersionMarkerPath)"
    }

    /// Reads the active version from the `current` marker; stdout is the
    /// version string (empty when absent).
    var readActiveVersionCommand: String {
        "cat \(currentVersionMarkerPath) 2>/dev/null"
    }

    /// Inspects the Host in one round trip: platform marker, home
    /// directory, Node version, omp presence, install-root presence,
    /// active version, socket, and service status. Every line is
    /// `key=value` framed so login-shell chatter cannot be misparsed.
    var inspectCommand: String {
        let ompProbe = "command -v omp >/dev/null 2>&1 && printf present || printf absent"
        let nodeProbe = "node --version 2>/dev/null || printf none"
        let installProbe = "test -f \(currentVersionMarkerPath) && printf present || printf absent"
        let socketProbe = "test -S \(socketPath) && printf present || printf absent"
        let serviceProbe = serviceActiveProbeCommand
        return "/bin/sh -c '"
            + "printf \"platform=%s\\n\" \"$(uname)\"; "
            + "printf \"home=%s\\n\" \"${HOME:-\"\"}\"; "
            + "printf \"node=%s\\n\" \"$( \(nodeProbe) )\"; "
            + "printf \"omp=%s\\n\" \"$( \(ompProbe) )\"; "
            + "printf \"installed=%s\\n\" \"$( \(installProbe) )\"; "
            + "printf \"version=%s\\n\" \"$( \(readActiveVersionCommand) )\"; "
            + "printf \"socket=%s\\n\" \"$( \(socketProbe) )\"; "
            + "printf \"service=%s\\n\" \"$( \(serviceProbe) )\"; "
            + "exit 0'"
    }

    /// The service-active probe. POSIX `sh` cannot hold a multi-line
    /// alternative body inside the single-quoted inspect script, so the
    /// per-platform probe is inlined per branch.
    private var serviceActiveProbeCommand: String {
        switch platform {
        case .linux:
            return "systemctl --user is-active --quiet \(serviceName) "
                + "&& printf active || printf inactive"
        case .macOS:
            return "launchctl print gui/$(id -u)/\(serviceName) "
                + "2>/dev/null | grep -q 'state = running' "
                + "&& printf active || printf inactive"
        }
    }

    /// One status value for the service: `active`, `inactive`, or
    /// `absent` (the unit is not installed at all).
    var serviceStatusProbeCommand: String {
        let probe = serviceActiveProbeCommand
        let unitExists: String
        switch platform {
        case .linux:
            unitExists = "systemctl --user cat \(serviceName) >/dev/null 2>&1 "
                + "&& printf unit-present || printf unit-absent"
        case .macOS:
            unitExists = "test -f ~/Library/LaunchAgents/\(serviceName).plist "
                + "&& printf unit-present || printf unit-absent"
        }
        return "/bin/sh -c '"
            + "printf \"unit=%s\\n\" \"$( \(unitExists) )\"; "
            + "printf \"state=%s\\n\" \"$( \(probe) )\"; "
            + "exit 0'"
    }

    /// Full inspect (host + prerequisites + install state + service
    /// state), one round trip.
    var serviceInspectCommand: String {
        inspectCommand
    }

    /// `mkdir -p` with owner-only permissions (0700) for every directory
    /// in the footprint. Idempotent; existing dirs are chmod'ed to 0700.
    var ensureDirectoriesCommand: String {
        let dirs = [versionsDirectory, dataRoot, configRoot, stateRoot, logsDirectory, adapterDirectory]
        let makes = dirs.map { "mkdir -p \($0) && chmod 700 \($0)" }.joined(separator: "; ")
        return "/bin/sh -c '\(makes); exit 0'"
    }

    /// Writes `contents` to `path` atomically (tmp + rename), mode 0600.
    /// `contents` is passed as base64 so no quoting hazards exist; the
    /// host decodes with `base64 -d` (present on every target: GNU
    /// coreutils and macOS both).
    func writePrivateFileCommand(path: String, base64Contents: String) -> String {
        "printf '%s' '\(base64Contents)' | base64 -d > \(path).tmp "
            + "&& chmod 600 \(path).tmp "
            + "&& mv \(path).tmp \(path)"
    }

    /// Writes the service env file (`broker.env`) atomically, containing
    /// every key from `environment` plus the derived socket/log paths.
    func writeBrokerEnvironmentCommand(
        environment: [String: String]
    ) throws -> String {
        var lines: [String] = [
            "HEELER_CHAT_SOCKET=\(socketPath)",
            "HEELER_CHAT_LOG_DIR=\(logsDirectory)",
        ]
        for (key, value) in environment.sorted(by: { $0.key < $1.key }) {
            guard Self.quoted(value) != nil else {
                throw BrokerProvisioningError.layoutPathUnsafe
            }
            lines.append("\(key)=\(value)")
        }
        let contents = lines.joined(separator: "\n") + "\n"
        let base64 = Data(contents.utf8).base64EncodedString()
        return writePrivateFileCommand(path: brokerEnvironmentFilePath, base64Contents: base64)
    }

    /// The adapter env file path (inside the adapter dir, our shim space).
    var adapterEnvironmentFilePath: String {
        "\(adapterDirectory)/adapter.env"
    }

    /// Writes the adapter env file. The ask-wrapper flag is written only
    /// when the user explicitly opted in — its absence is the OFF default,
    /// so an upgrade that forgets to re-request it stays off.
    func writeAdapterEnvironmentCommand(askWrapperOptIn: Bool) -> String {
        var lines = ["HEELER_CHAT_SOCKET=\(socketPath)"]
        if askWrapperOptIn {
            lines.append("\(Self.askWrapperEnvironmentKey)=1")
        }
        let contents = lines.joined(separator: "\n") + "\n"
        let base64 = Data(contents.utf8).base64EncodedString()
        return writePrivateFileCommand(
            path: adapterEnvironmentFilePath, base64Contents: base64)
    }

    /// Reads the adapter env file (stdout is its raw text; empty when
    /// absent) — the inspect probe's "adapter configured" evidence.
    var readAdapterEnvironmentCommand: String {
        "cat \(adapterEnvironmentFilePath) 2>/dev/null"
    }

    /// The systemd unit body. `ExecStart` points at the active version's
    /// broker entrypoint via the `current` marker, so a version swap needs
    /// a service restart (surfaced as `restartsRequired`).
    func systemdUnitBody(activeVersion: String) -> String {
        """
        [Unit]
        Description=Heeler Chat Broker

        [Service]
        Type=simple
        ExecStart=\(brokerExecutablePath(activeVersion: activeVersion))
        EnvironmentFile=\(brokerEnvironmentFilePath)
        Restart=on-failure
        RestartSec=2

        [Install]
        WantedBy=default.target
        """
    }

    /// The launchd plist body for macOS.
    func launchdPlistBody(activeVersion: String) -> String {
        let escaped = { (value: String) -> String in
            value.replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
                .replacingOccurrences(of: "\"", with: "&quot;")
        }
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(serviceName)</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(escaped(brokerExecutablePath(activeVersion: activeVersion)))</string>
            </array>
            <key>EnvironmentVariables</key>
            <dict>
                <key>HEELER_CHAT_SOCKET</key>
                <string>\(escaped(socketPath))</string>
                <key>HEELER_CHAT_LOG_DIR</key>
                <string>\(escaped(logsDirectory))</string>
            </dict>
            <key>RunAtLoad</key>
            <true/>
            <key>KeepAlive</key>
            <true/>
            <key>StandardOutPath</key>
            <string>\(escaped("\(logsDirectory)/broker.log"))</string>
            <key>StandardErrorPath</key>
            <string>\(escaped("\(logsDirectory)/broker.err.log"))</string>
        </dict>
        </plist>
        """
    }

    /// The unit file path as the platform writes it (used for both the
    /// unit write and uninstall).
    var unitInstallPath: String {
        switch platform {
        case .linux: "\(configRoot)/../systemd/user/\(serviceName).service"
        case .macOS:
            // macOS has no HOME-independent shortcut here; the store
            // resolves HOME before building commands.
            "~/Library/LaunchAgents/\(serviceName).plist"
        }
    }

    /// Writes the service unit (systemd user unit or launchd plist)
    /// atomically, given the active version the unit should start.
    func writeUnitCommand(activeVersion: String) throws -> String {
        let body: String
        switch platform {
        case .linux: body = systemdUnitBody(activeVersion: activeVersion)
        case .macOS: body = launchdPlistBody(activeVersion: activeVersion)
        }
        let base64 = Data(body.utf8).base64EncodedString()
        return writePrivateFileCommand(path: unitInstallPath, base64Contents: base64)
    }

    /// Enables and starts the service (user-level only; no sudo).
    var enableServiceCommand: String {
        switch platform {
        case .linux:
            return "/bin/sh -c 'systemctl --user daemon-reload; "
                + "systemctl --user enable --now \(serviceName)'"
        case .macOS:
            return "/bin/sh -c 'launchctl bootout gui/$(id -u)/\(serviceName) "
                + "2>/dev/null; launchctl bootstrap gui/$(id -u) "
                + "~/Library/LaunchAgents/\(serviceName).plist'"
        }
    }

    /// Disables and stops the service.
    var disableServiceCommand: String {
        switch platform {
        case .linux:
            return "/bin/sh -c 'systemctl --user disable --now \(serviceName)'"
        case .macOS:
            return "/bin/sh -c 'launchctl bootout gui/$(id -u)/\(serviceName) 2>/dev/null; exit 0'"
        }
    }

    /// The checksum command for the platform's native utility.
    var checksumCommandPrefix: String {
        switch platform {
        case .linux: "sha256sum"
        case .macOS: "shasum -a 256"
        }
    }

    /// Verifies a staged file's checksum remotely: prints `ok` on match.
    func remoteChecksumCommand(path: String, expectedSHA256: String) throws -> String {
        guard Self.quoted(expectedSHA256) != nil, Self.quoted(path) != nil else {
            throw BrokerProvisioningError.layoutPathUnsafe
        }
        return "actual=$( \(checksumCommandPrefix) \(path) 2>/dev/null | cut -d' ' -f1 ); "
            + "test \"$actual\" = '\(expectedSHA256)' && printf ok || printf mismatch"
    }

    /// Extracts a staged tarball into a fresh `.incomplete` version dir,
    /// then verifies the manifest and permissions before the atomic swap.
    func extractToIncompleteCommand(
        stagedPath: String, version: String
    ) throws -> String {
        guard Self.quoted(stagedPath) != nil, Self.quoted(version) != nil else {
            throw BrokerProvisioningError.layoutPathUnsafe
        }
        let target = "\(versionsDirectory)/\(version).incomplete"
        return "/bin/sh -c '"
            + "rm -rf \(target); "
            + "mkdir -p \(target) && chmod 700 \(target); "
            + "tar -xzf \(stagedPath) -C \(target) || exit 1; "
            + "test -x \(target)/broker/bin/broker || exit 2; "
            + "test -f \(target)/broker/manifest.json || exit 3; "
            + "exit 0'"
    }

    /// Promotes the `.incomplete` dir to its final version name (rename(2),
    /// atomic), then swaps the `current` marker.
    func promoteVersionCommand(version: String) throws -> String {
        guard Self.quoted(version) != nil else {
            throw BrokerProvisioningError.layoutPathUnsafe
        }
        let target = "\(versionsDirectory)/\(version)"
        let incomplete = "\(target).incomplete"
        let swap = try swapCurrentMarkerCommand(version: version)
        return "/bin/sh -c '"
            + "mv \(incomplete) \(target) && \(swap) && exit 0 "
            + "|| { rm -rf \(incomplete); exit 1; }'"
    }

    /// Removes old version directories, keeping only `keep` (and `current`
    /// marker). Sessions/history live outside the data root, so this
    /// touches nothing user-authored.
    func pruneOldVersionsCommand(keep: String) throws -> String {
        guard Self.quoted(keep) != nil else {
            throw BrokerProvisioningError.layoutPathUnsafe
        }
        return "/bin/sh -c 'cd \(versionsDirectory) "
            + "&& ls | grep -v \"^\\(current\\|\(keep)\\)$\" | xargs rm -rf; exit 0'"
    }

    /// Uninstalls the service unit + helper-owned trees ONLY: data root,
    /// config root, unit file, state root minus sessions. The broker's
    /// own sessions/history (wherever the runtime keeps them) are
    /// outside this footprint by design and are never touched.
    var uninstallCommand: String {
        let disable = disableServiceCommand
        let rmUnit: String
        switch platform {
        case .linux: rmUnit = "rm -f \(unitInstallPath); systemctl --user daemon-reload"
        case .macOS: rmUnit = "rm -f ~/Library/LaunchAgents/\(serviceName).plist"
        }
        return "/bin/sh -c '\(disable); \(rmUnit); "
            + "rm -rf \(dataRoot) \(configRoot); "
            + "rm -f \(socketPath); exit 0'"
    }
}
