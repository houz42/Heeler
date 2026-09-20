import Foundation

/// One address form row. The id is SwiftUI's row identity: it is assigned
/// when the row is created and never changes while the row lives, so
/// typing into the field (which rewrites `address` every keystroke) cannot
/// tear the row down and drop the keyboard. The string value cannot be the
/// identity — that is the bug this type exists to prevent.
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
    /// Every way to reach the Host, one row each; the FIRST row is the
    /// primary `Host.address`, the rest become `additionalAddresses`. A
    /// single list so the form treats every address identically — removing
    /// the primary just promotes the next row — with a floor of one row:
    /// a Host must always be reachable somewhere.
    var addresses: [AdditionalAddressRow] = [AdditionalAddressRow()]
    /// The primary address — the first row. Reads and writes go to row 0;
    /// removing it (the floor keeps a row present) promotes the next row
    /// into the slot.
    var address: String {
        get { addresses.first?.address ?? "" }
        set { addresses[0].address = newValue }
    }
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

    init() {}

    /// Prefill for editing an existing Host.
    init(host: Host) {
        name = host.name
        addresses = host.candidateAddresses.map { AdditionalAddressRow(address: $0) }
        if addresses.isEmpty {
            addresses = [AdditionalAddressRow()]
        }
        port = String(host.port)
        username = host.username
        authMethod = host.authMethod
        sessionName = host.sessionName
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
        let trimmed = normalizedAddresses
        return Host(
            id: id,
            name: name.trimmingCharacters(in: .whitespaces),
            address: trimmed.first ?? "",
            port: portNumber,
            username: username.trimmingCharacters(in: .whitespaces),
            authMethod: authMethod,
            sessionName: sessionName.trimmingCharacters(in: .whitespaces),
            additionalAddresses: Array(trimmed.dropFirst()),
            jumpAddress: jumpAddress.trimmingCharacters(in: .whitespaces),
            jumpPort: jumpPortNumber ?? 22,
            jumpUsername: jumpUsername.trimmingCharacters(in: .whitespaces),
            alias: trimmedAlias)
    }

    /// The form's addresses as dialed: trimmed, empty entries dropped, order
    /// preserved. The first entry is the primary; `candidateAddresses` and
    /// the dialer see the same list.
    var normalizedAddresses: [String] {
        addresses
            .map { $0.address.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Appends one address row. A blank row is a no-op — the row exists to
    /// be typed into; saving drops it instead of rejecting.
    mutating func addAddress(_ address: String = "") {
        addresses.append(AdditionalAddressRow(address: address))
    }

    /// Removes the row with `id` — ANY row, the primary included: removing
    /// the first row promotes the next remaining row to primary. The floor
    /// is one row total; removing the last one is a no-op.
    mutating func removeAddress(id: UUID) {
        guard addresses.count > 1 else { return }
        addresses.removeAll { $0.id == id }
    }

    /// Reorders the rows after an EditMode/onDelete OnMove. Position 0 is
    /// the primary, so moving a row to the front promotes it.
    mutating func moveAddresses(from source: IndexSet, to destination: Int) {
        addresses.move(fromOffsets: source, toOffset: destination)
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
