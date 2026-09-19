import Foundation

/// One additional-address form row. The id is SwiftUI's row identity: it is
/// assigned when the row is created and never changes while the row lives,
/// so typing into the field (which rewrites `address` every keystroke)
/// cannot tear the row down and drop the keyboard. The string value cannot
/// be the identity — that is the bug this type exists to prevent.
struct AdditionalAddressRow: Equatable, Identifiable, Sendable {
    let id: UUID
    var address: String

    init(id: UUID = UUID(), address: String = "") {
        self.id = id
        self.address = address
    }
}

/// Editable form state behind `HostFormView`, validated before it becomes a
/// catalog Host. Text-field friendly (port is a string) so the view stays
/// dumb and the rules stay testable.
struct HostDraft: Equatable, Sendable {
    var name = ""
    var address = ""
    var port = "22"
    var username = ""
    var authMethod: Host.AuthMethod = .deviceKey
    /// Blank means "keep the stored password" when editing.
    var password = ""
    var sessionName = ""
    /// Alternative addresses for the same machine, dialed in order after
    /// Address when it does not answer. One row per form line; empty means
    /// single-path. Rows carry stable ids (see `AdditionalAddressRow`).
    var additionalAddresses: [AdditionalAddressRow] = []
    /// Blank means a direct connection. When set, Address/Port above are
    /// resolved from the Jump Host, not from this device.
    var jumpAddress = ""
    var jumpPort = "22"
    /// Blank reuses the Host's own username.
    var jumpUsername = ""
    /// Optional presentation alias; blank means no alias.
    var alias = ""

    init() {}

    /// Prefill for editing an existing Host.
    init(host: Host) {
        name = host.name
        address = host.address
        port = String(host.port)
        username = host.username
        authMethod = host.authMethod
        sessionName = host.sessionName
        additionalAddresses = host.additionalAddresses.map {
            AdditionalAddressRow(address: $0)
        }
        jumpAddress = host.jumpAddress
        jumpPort = String(host.jumpPort)
        jumpUsername = host.jumpUsername
        alias = host.alias ?? ""
    }

    var portNumber: Int? {
        guard let value = Int(port), (1...65535).contains(value) else { return nil }
        return value
    }

    var jumpPortNumber: Int? {
        guard let value = Int(jumpPort), (1...65535).contains(value) else { return nil }
        return value
    }

    var usesJumpHost: Bool {
        !jumpAddress.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var isValid: Bool {
        let trimmedSessionName = sessionName.trimmingCharacters(in: .whitespaces)
        return !address.trimmingCharacters(in: .whitespaces).isEmpty
            && !username.trimmingCharacters(in: .whitespaces).isEmpty
            && portNumber != nil
            && (trimmedSessionName.isEmpty || HerdrSessionName.isValid(trimmedSessionName))
            // A blank jump address disables the hop entirely, so its port only
            // has to parse when the hop is actually in use.
            && (!usesJumpHost || jumpPortNumber != nil)
    }

    /// Form-level validity including credential intent. A blank password can
    /// only mean "keep current" when the existing Host already used password
    /// authentication; new Hosts and Device Key -> Password changes require
    /// an actual secret to persist.
    func canSave(editing existingHost: Host?) -> Bool {
        guard isValid else { return false }
        guard authMethod == .password, password.isEmpty else { return true }
        return existingHost?.authMethod == .password
    }

    /// The catalog Host this draft describes, or nil while invalid. Pass the
    /// existing id when editing so the Host keeps its identity (and its
    /// Keychain password account).
    func makeHost(id: UUID = UUID()) -> Host? {
        guard isValid, let portNumber else { return nil }
        return Host(
            id: id,
            name: name.trimmingCharacters(in: .whitespaces),
            address: address.trimmingCharacters(in: .whitespaces),
            port: portNumber,
            username: username.trimmingCharacters(in: .whitespaces),
            authMethod: authMethod,
            sessionName: sessionName.trimmingCharacters(in: .whitespaces),
            additionalAddresses: normalizedAdditionalAddresses,
            jumpAddress: jumpAddress.trimmingCharacters(in: .whitespaces),
            jumpPort: jumpPortNumber ?? 22,
            jumpUsername: jumpUsername.trimmingCharacters(in: .whitespaces),
            alias: trimmedAlias)
    }

    /// The form's additional rows as addresses: trimmed, empty entries
    /// dropped. Everything (decode, the form, the dialer) sees the same
    /// candidate list.
    var normalizedAdditionalAddresses: [String] {
        additionalAddresses
            .map { $0.address.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Appends one additional-address row. A blank row is a no-op — the
    /// row exists to be typed into; saving drops it instead of rejecting.
    mutating func addAdditionalAddress(_ address: String = "") {
        additionalAddresses.append(AdditionalAddressRow(address: address))
    }

    /// Removes the additional row with `id`. Additional rows only: the
    /// primary address is not part of this list and cannot be removed, so a
    /// Host always keeps at least one dialable address.
    mutating func removeAdditionalAddress(id: UUID) {
        additionalAddresses.removeAll { $0.id == id }
    }

    /// Reorders the additional rows after an EditMode/onDelete OnMove. The
    /// primary address stays first regardless of `destination`.
    mutating func moveAdditionalAddress(from source: IndexSet, to destination: Int) {
        additionalAddresses.move(fromOffsets: source, toOffset: destination)
    }

    /// A whitespace-only alias is no alias: trimmed, and nil when blank, so
    /// the form and decode agree on what "no alias" is.
    private var trimmedAlias: String? {
        let trimmed = alias.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// What to hand `HostStore.add/update` as the password argument: a new
    /// secret to store, or nil for "leave storage as it is".
    var passwordUpdate: String? {
        guard authMethod == .password, !password.isEmpty else { return nil }
        return password
    }
}
