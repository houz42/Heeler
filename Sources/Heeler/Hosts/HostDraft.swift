import Foundation

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
    /// Blank means a direct connection. When set, Address/Port above are
    /// resolved from the Jump Host, not from this device.
    var jumpAddress = ""
    var jumpPort = "22"
    /// Blank reuses the Host's own username.
    var jumpUsername = ""
    /// Optional presentation alias; blank means no alias.
    var alias = ""
    /// Optional native chat broker socket path on the Host; blank means
    /// no broker (the chat surface stays on the transcript backend).
    var brokerChatSocketPath = ""

    init() {}

    /// Prefill for editing an existing Host.
    init(host: Host) {
        name = host.name
        address = host.address
        port = String(host.port)
        username = host.username
        authMethod = host.authMethod
        sessionName = host.sessionName
        jumpAddress = host.jumpAddress
        jumpPort = String(host.jumpPort)
        jumpUsername = host.jumpUsername
        alias = host.alias ?? ""
        brokerChatSocketPath = host.brokerChatSocketPath
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
            jumpAddress: jumpAddress.trimmingCharacters(in: .whitespaces),
            jumpPort: jumpPortNumber ?? 22,
            jumpUsername: jumpUsername.trimmingCharacters(in: .whitespaces),
            alias: trimmedAlias,
            brokerChatSocketPath: brokerChatSocketPath.trimmingCharacters(in: .whitespaces))
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
