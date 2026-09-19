import Foundation

/// A user-added Host (CONTEXT.md): connection coordinates, how to
/// authenticate, and which herdr session to reach. Never carries a secret —
/// the password lives in the Keychain keyed by `id`, the device key in
/// `DeviceKeyStore`.
struct Host: Identifiable, Codable, Hashable, Sendable {
    /// How the app authenticates against this Host. OpenSSH key import is
    /// deliberately absent (out of scope per spec #20).
    enum AuthMethod: String, Codable, Sendable {
        case deviceKey
        case password
    }

    let id: UUID
    /// Optional display label; blank falls back to `user@address`.
    var name: String
    var address: String
    var port: Int
    var username: String
    var authMethod: AuthMethod
    /// Persisted session selection; onboarding discovers available sessions,
    /// while this field remains editable for older herdr versions. Blank
    /// means the default herdr session.
    var sessionName: String
    /// Optional Jump Host this Host is reached through. Blank means a direct
    /// connection; when set, `address`/`port` are resolved from the Jump Host
    /// and normally point at a loopback port held open by a reverse tunnel.
    var jumpAddress: String
    var jumpPort: Int
    /// Account on the Jump Host. Blank reuses `username`, which is the common
    /// case only when both machines share an account name.
    var jumpUsername: String
    /// User-assignable label shown instead of `name` wherever the Host is
    /// presented. Nil (or whitespace-only) means no alias and `name` shows.
    /// A separate field from `name` on purpose: `name` is the user's primary
    /// label for the connection, while the alias is presentation-only.
    var alias: String?

    /// Absolute path of the native chat broker's Unix socket on this
    /// Host (reached over the same SSH connection's direct-streamlocal
    /// forwarding). Blank means no broker configured; the chat surface
    /// then stays on the JSONL transcript backend.
    var brokerChatSocketPath: String

    /// `socatPath` is deliberately absent: Hosts serialized before ADR 0011
    /// still carry it on disk, and leaving it out of the keys both ignores it
    /// on decode and drops it on the Host's next save.
    private enum CodingKeys: String, CodingKey {
        case id, name, address, port, username, authMethod, sessionName
        case jumpAddress, jumpPort, jumpUsername, alias
        case brokerChatSocketPath = "broker_chat_socket_path"
    }

    /// Whether this Host is reached through a Jump Host.
    var usesJumpHost: Bool {
        !jumpAddress.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// The Jump Host account, falling back to the Host's own username.
    var resolvedJumpUsername: String {
        let trimmed = jumpUsername.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? username : trimmed
    }

    init(
        id: UUID = UUID(),
        name: String = "",
        address: String,
        port: Int = 22,
        username: String,
        authMethod: AuthMethod = .deviceKey,
        sessionName: String = "",
        jumpAddress: String = "",
        jumpPort: Int = 22,
        jumpUsername: String = "",
        alias: String? = nil,
        brokerChatSocketPath: String = ""
    ) {
        self.id = id
        self.name = name
        self.address = address
        self.port = port
        self.username = username
        self.authMethod = authMethod
        self.sessionName = sessionName
        self.jumpAddress = jumpAddress
        self.jumpPort = jumpPort
        self.jumpUsername = jumpUsername
        self.alias = alias
        self.brokerChatSocketPath = brokerChatSocketPath
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        address = try container.decode(String.self, forKey: .address)
        port = try container.decode(Int.self, forKey: .port)
        username = try container.decode(String.self, forKey: .username)
        authMethod = try container.decode(AuthMethod.self, forKey: .authMethod)
        sessionName = try container.decodeIfPresent(String.self, forKey: .sessionName) ?? ""
        // Absent in Hosts saved before jump-host support; a blank address
        // decodes as the direct connection those Hosts already had.
        jumpAddress = try container.decodeIfPresent(String.self, forKey: .jumpAddress) ?? ""
        jumpPort = try container.decodeIfPresent(Int.self, forKey: .jumpPort) ?? 22
        jumpUsername = try container.decodeIfPresent(String.self, forKey: .jumpUsername) ?? ""
        // Absent in Hosts saved before aliases; a whitespace-only persisted
        // alias decodes as nil so presentation never shows a blank label.
        alias = try container.decodeIfPresent(String.self, forKey: .alias)
            .flatMap { Self.normalizedAlias($0) }
        brokerChatSocketPath =
            try container.decodeIfPresent(String.self, forKey: .brokerChatSocketPath) ?? ""

        let trimmedSessionName = sessionName.trimmingCharacters(in: .whitespaces)
        guard trimmedSessionName.isEmpty || HerdrSessionName.isValid(trimmedSessionName) else {
            throw DecodingError.dataCorruptedError(
                forKey: .sessionName, in: container, debugDescription: "Invalid herdr session name")
        }
    }

    /// A stored alias is only meaningful when it renders: trimmed, and nil
    /// when empty. One normalization so decode, the form, and the list all
    /// agree on what "no alias" is.
    private static func normalizedAlias(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "\(username)@\(address)" : trimmed
    }

    /// The name every Host surface shows: the alias when it renders, `name`
    /// (itself falling back to `user@address`) otherwise. Decode and the
    /// form already normalize stored aliases, so the blank check only
    /// guards direct construction.
    var displayAliasName: String {
        guard let alias, !alias.trimmingCharacters(in: .whitespaces).isEmpty else {
            return displayName
        }
        return alias
    }

    /// The herdr socket this Host's session name points at.
    var socketLocation: HerdrSocketLocation {
        let trimmed = sessionName.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? .defaultSession : .namedSession(trimmed)
    }

    /// Whether this Host has a chat broker configured.
    var hasBrokerChat: Bool {
        !brokerChatSocketPath.trimmingCharacters(in: .whitespaces).isEmpty
    }
}
