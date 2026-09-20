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
    /// Alternative addresses that reach the same physical Host over a
    /// different network path (home LAN vs VPN, for example). Dialed in
    /// order after `address`; see ``candidateAddresses``. Empty means the
    /// Host has exactly one way to be reached, like every Host saved before
    /// this field existed.
    var additionalAddresses: [String]

    /// User-assignable names for connection routes: the label each route
    /// row carries on the Host card, the route editor, and the route
    /// inspector (handoff §E). Keyed by exact address so `address` and
    /// `additionalAddresses` keep their plain-string dialing contract;
    /// `routeName(for:)` resolves presentation, with the address itself as
    /// the fallback label. Pruned to only cover live candidates.
    var routeLabels: [String: String]
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

    /// `socatPath` is deliberately absent: Hosts serialized before ADR 0011
    /// still carry it on disk, and leaving it out of the keys both ignores it
    /// on decode and drops it on the Host's next save.
    private enum CodingKeys: String, CodingKey {
        case id, name, address, port, username, authMethod, sessionName
        case additionalAddresses, routeLabels, jumpAddress, jumpPort, jumpUsername, alias
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

    /// The dialing order: the stored default `address` first, then each
    /// additional address in stored order. The stored default stays first so
    /// existing Hosts never change which path wins while it works.
    var candidateAddresses: [String] {
        ([address] + additionalAddresses)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    init(
        id: UUID = UUID(),
        name: String = "",
        address: String,
        port: Int = 22,
        username: String,
        authMethod: AuthMethod = .deviceKey,
        sessionName: String = "",
        additionalAddresses: [String] = [],
        routeLabels: [String: String] = [:],
        jumpAddress: String = "",
        jumpPort: Int = 22,
        jumpUsername: String = "",
        alias: String? = nil
    ) {
        self.id = id
        self.name = name
        self.address = address
        self.port = port
        self.username = username
        self.authMethod = authMethod
        self.sessionName = sessionName
        self.additionalAddresses = Self.normalizedAdditionalAddresses(additionalAddresses)
        self.routeLabels = Self.normalizedRouteLabels(
            routeLabels,
            candidates: Self.rawCandidates(address: address, additional: additionalAddresses))
        self.jumpAddress = jumpAddress
        self.jumpPort = jumpPort
        self.jumpUsername = jumpUsername
        self.alias = alias
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
        // Absent in Hosts saved before multi-path addresses; those Hosts
        // keep their single reachable address unchanged.
        additionalAddresses =
            try container.decodeIfPresent([String].self, forKey: .additionalAddresses)
            .map(Self.normalizedAdditionalAddresses) ?? []
        // Absent in Hosts saved before named routes; unlabeled addresses
        // keep their address-as-label presentation unchanged.
        routeLabels =
            try container.decodeIfPresent([String: String].self, forKey: .routeLabels) ?? [:]
        // Absent in Hosts saved before jump-host support; a blank address
        // decodes as the direct connection those Hosts already had.
        jumpAddress = try container.decodeIfPresent(String.self, forKey: .jumpAddress) ?? ""
        jumpPort = try container.decodeIfPresent(Int.self, forKey: .jumpPort) ?? 22
        jumpUsername = try container.decodeIfPresent(String.self, forKey: .jumpUsername) ?? ""
        // Absent in Hosts saved before aliases; a whitespace-only persisted
        // alias decodes as nil so presentation never shows a blank label.
        alias = try container.decodeIfPresent(String.self, forKey: .alias)
            .flatMap { Self.normalizedAlias($0) }

        let trimmedSessionName = sessionName.trimmingCharacters(in: .whitespaces)
        guard trimmedSessionName.isEmpty || HerdrSessionName.isValid(trimmedSessionName) else {
            throw DecodingError.dataCorruptedError(
                forKey: .sessionName, in: container, debugDescription: "Invalid herdr session name")
        }
        routeLabels = Self.normalizedRouteLabels(routeLabels, candidates: candidateAddresses)
    }

    /// The presentation name of one connection route: the user's label
    /// when it renders, the address otherwise. One resolution so the card,
    /// the editor, and the inspector never disagree.
    func routeName(for address: String) -> String {
        if let label = routeLabels[address]?.trimmingCharacters(in: .whitespaces),
            !label.isEmpty
        {
            return label
        }
        return address
    }

    /// A route label only counts when it renders and still belongs to a
    /// live candidate: trimmed, blanks dropped, stale keys (the address
    /// was edited or removed since the label was set) pruned so a Host's
    /// saved label map never accumulates dead entries.
    private static func normalizedRouteLabels(
        _ raw: [String: String], candidates: [String]
    ) -> [String: String] {
        let live = Set(candidates)
        var normalized: [String: String] = [:]
        for (address, label) in raw where live.contains(address) {
            let trimmed = label.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty {
                normalized[address] = trimmed
            }
        }
        return normalized
    }

    /// A stored alias is only meaningful when it renders: trimmed, and nil
    /// when empty. One normalization so decode, the form, and the list all
    /// agree on what "no alias" is.
    private static func normalizedAlias(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// An additional address only counts when it dials: trimmed, empty
    /// dropped. One normalization so decode, the form, and the dialer all
    /// agree on what a candidate is.
    private static func normalizedAdditionalAddresses(_ raw: [String]) -> [String] {
        raw.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "\(username)@\(address)" : trimmed
    }

    /// Candidate addresses from raw init arguments, for normalization that
    /// runs before all stored properties are initialized.
    private static func rawCandidates(address: String, additional: [String]) -> [String] {
        ([address] + additional)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// The name every Host surface shows: the alias when it renders, `name`
    /// (itself falling back to `user@address`) otherwise. Decode and the
    /// form already normalize stored aliases, so the blank check only
    /// guards direct construction.
    ///
    /// A label that exactly matches one of the Host's candidate addresses
    /// is skipped: an address in the title slot is address-as-label
    /// pollution (typed into the wrong field), never a name, and showing
    /// it turns the Hosts list into a list of addresses with the real name
    /// nowhere. The chain falls to the next label instead.
    var displayAliasName: String {
        let candidates = Set(candidateAddresses.map { $0.lowercased() })
        if let alias, !alias.trimmingCharacters(in: .whitespaces).isEmpty,
            !candidates.contains(alias.lowercased())
        {
            return alias
        }
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        if !trimmedName.isEmpty, !candidates.contains(trimmedName.lowercased()) {
            return trimmedName
        }
        return "\(username)@\(address)"
    }

    /// The herdr socket this Host's session name points at.
    var socketLocation: HerdrSocketLocation {
        let trimmed = sessionName.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? .defaultSession : .namedSession(trimmed)
    }
}
