import SwiftUI

/// Editable priority/eligibility state behind `HostRouteEditorView`.
/// Labels and addresses stay in the v1 Host form (one editor per
/// concern): this editor owns the v2-only settings — the dialing PRIORITY
/// (row order) and each route's eligibility gate. Text-field friendly so
/// the view stays dumb and the rules stay testable; mirrors `HostDraft`'s
/// row-identity pattern (a stable UUID per row so reordering cannot tear
/// rows down).
struct HostRoutePriorityDraft: Equatable, Sendable {
    struct Row: Equatable, Identifiable, Sendable {
        let id: UUID
        /// The route's address — read-only here (edited in the v1 form).
        let address: String
        var eligibility: HostRouteEligibility

        init(id: UUID = UUID(), address: String, eligibility: HostRouteEligibility) {
            self.id = id
            self.address = address
            self.eligibility = eligibility
        }
    }

    var rows: [Row]

    /// Prefill from a Host: candidates in saved priority order, each
    /// with its saved eligibility (Any network when never set).
    init(host: Host) {
        rows = host.candidateAddresses.map {
            Row(address: $0, eligibility: host.routeEligibility(for: $0))
        }
    }

    /// The eligibility map this draft persists, keyed by address.
    func makeEligibility() -> [String: HostRouteEligibility] {
        Dictionary(uniqueKeysWithValues: rows.map { ($0.address, $0.eligibility) })
    }

    /// The reordered address list this draft persists: the new saved
    /// priority. Empty rows cannot occur (addresses are read-only).
    func makePriority() -> [String] {
        rows.map(\.address)
    }

    /// Whether anything changed against `host` — Save stays honest about
    /// being a no-op.
    func differs(from host: Host) -> Bool {
        makePriority() != host.candidateAddresses
            || makeEligibility() != host.routeEligibility
    }

    mutating func moveRows(from source: IndexSet, to destination: Int) {
        rows.move(fromOffsets: source, toOffset: destination)
    }
}

/// Edits one Host's route PRIORITY and ELIGIBILITY (the v2 settings):
/// drag to reorder the dialing priority, and set each route's Any
/// network / Wi-Fi only gate. Saving rewrites the Host's address order
/// and eligibility map together through one catalog update, so the
/// priority list and the dial coordinates can never disagree.
struct HostRouteEditorView: View {
    let host: Host
    let catalog: HostStore
    @Environment(\.dismiss) private var dismiss
    @State private var draft: HostRoutePriorityDraft
    @State private var saveFailed = false

    init(host: Host, catalog: HostStore) {
        self.host = host
        self.catalog = catalog
        _draft = State(initialValue: HostRoutePriorityDraft(host: host))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach($draft.rows) { $row in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(host.routeName(for: row.address))
                                    .font(.subheadline)
                                Text(row.address)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Picker("Eligibility", selection: $row.eligibility) {
                                Text("Any network").tag(HostRouteEligibility.anyNetwork)
                                Text("Wi-Fi only").tag(HostRouteEligibility.wifiOnly)
                            }
                            .pickerStyle(.menu)
                        }
                    }
                    .onMove { source, destination in
                        draft.moveRows(from: source, to: destination)
                    }
                } header: {
                    Text("Saved priority")
                } footer: {
                    Text(
                        "Routes are dialed top to bottom until one answers. "
                            + "Drag to change the priority. “Wi-Fi only” routes "
                            + "are skipped while the current network is not "
                            + "Wi-Fi. Route names and addresses are edited in "
                            + "the Host form.")
                }
            }
            .navigationTitle("Routes · \(host.displayName)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(!draft.differs(from: host))
                }
                ToolbarItem(placement: .primaryAction) {
                    EditButton()
                }
            }
            .alert("Could not save routes", isPresented: $saveFailed) {
                Button("OK", role: .cancel) {}
            }
        }
    }

    /// Persists the new priority (address order) and eligibility map in
    /// ONE Host update, so the route list and the dial coordinates stay
    /// in lockstep. The pin (if any) is carried untouched — reordering
    /// never reinterprets a pin; a pin whose address still exists keeps
    /// dialing it wherever it sits in the priority.
    private func save() {
        let priority = draft.makePriority()
        var updated = host
        guard let first = priority.first else { return }
        updated.address = first
        updated.additionalAddresses = Array(priority.dropFirst())
        updated.routeEligibility = draft.makeEligibility()
        do {
            try catalog.update(updated)
            dismiss()
        } catch {
            saveFailed = true
        }
    }
}
