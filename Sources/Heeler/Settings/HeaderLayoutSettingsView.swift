import SwiftUI

// SPDX-License-Identifier: Apache-2.0

/// Settings for the in-Agent header (the nav-bar principal on the chat and
/// terminal detail surfaces): follow the Host's agent-list layout, or a
/// separately configured global layout built with the same field chips.
///
/// The custom editor is the Agent List Fields editor itself, pointed at the
/// header store's nested catalog and its one fixed Host identity — same
/// fixed three slots, same chip menu (style, move, remove), same Add Field
/// sheet, same preview card — but writing one global preference instead of
/// a per-Host choice, so no Sync from plugin here.
struct HeaderLayoutSettingsView: View {
    let console: ConsoleStore
    let store: HeaderLayoutSettingsStore
    @State private var editor: AgentListFieldsEditor
    @State private var addingField: AgentListFieldsEditorDestination?
    @State private var errorMessage: String?

    init(console: ConsoleStore, store: HeaderLayoutSettingsStore) {
        self.console = console
        self.store = store
        // A real editor over the header's own catalog: the console's
        // snapshot store is only a constructor requirement here, never read
        // (no sync), and its fetch is unreachable.
        _editor = State(initialValue: AgentListFieldsEditor(
            layouts: store.layouts,
            snapshots: HerdrSidebarSnapshotStore(),
            fetch: { _ in nil }))
    }

    private var hostID: Host.ID { HeaderLayoutSettingsStore.customLayoutHostID }
    private var layout: AgentRowLayout { editor.layout(for: hostID) }
    private var isEditing: Bool { editor.isEditing }

    var body: some View {
        List {
            introSection
            modeSection
            if !isSameAsList {
                customSection
            }
            errorSection
        }
        .listStyle(.plain)
        .listSectionSpacing(AgentListFieldsChrome.hostSpacing)
        .contentMargins(.horizontal, AgentListFieldsChrome.pageInset, for: .scrollContent)
        .scrollContentBackground(.hidden)
        .background(Color(uiColor: .systemGroupedBackground))
        .listRowSeparatorTint(Color(uiColor: .separator))
        .frame(maxWidth: AgentListFieldsCopy.readableWidth)
        .frame(maxWidth: .infinity)
        .navigationTitle("In-Agent Header")
        .navigationBarTitleDisplayMode(.large)
        .sheet(item: $addingField) { destination in
            AgentListFieldsAddFieldSheet(
                editor: editor, destination: destination, hostName: "")
        }
        .onChange(of: editor.errorMessage) { _, message in
            if message != nil { errorMessage = message }
        }
    }

    private var isSameAsList: Bool { store.mode == .sameAsList }

    /// The toggle writes the store's mode; a refused write (unreadable
    /// catalog) keeps the switch where it was and explains below, where the
    /// custom editor shows only while the mode says custom.
    private var modeSection: some View {
        Section {
            Toggle(isOn: Binding(
                get: { isSameAsList },
                set: { isOn in
                    store.setMode(isOn ? .sameAsList : .custom)
                })) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Same as agent list")
                    Text(HeaderLayoutCopy.sameAsListCaption)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .disabled(editor.isCatalogUnreadable)
            .accessibilityIdentifier("settings.headerLayout.sameAsList")
        }
        .listSectionSeparator(.hidden)
    }

    private var introSection: some View {
        Section {
            Text(HeaderLayoutCopy.intro)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .listRowInsets(EdgeInsets(top: 4, leading: 4, bottom: 0, trailing: 4))
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .listSectionSeparator(.hidden)
    }

    private var customSection: some View {
        Section {
            previewRow
            rowEditors
            slotsNote
        }
        .listSectionSeparator(.hidden)
    }

    private var previewRow: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Header Preview")
                .font(.caption2.weight(.semibold))
                .tracking(0.5)
                .foregroundStyle(.tertiary)
                .textCase(.uppercase)
            AgentListFieldsPreview(layout: layout, hostName: HeaderLayoutCopy.previewHostName)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .listRowInsets(AgentListFieldsChrome.previewInsets)
        .agentListHostSurface(isFirst: true, isLast: false, fill: AgentListFieldsChrome.previewFill)
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private var rowEditors: some View {
        let slotRows = AgentRowSlot.slotRows(layout.rows)
        ForEach(Array(slotRows.enumerated()), id: \.offset) { index, row in
            AgentListFieldsRowEditor(
                index: index, row: row, isEnabled: !isEditing && !editor.isCatalogUnreadable,
                onAdd: {
                    addingField = AgentListFieldsEditorDestination(
                        hostID: hostID, rowIndex: index)
                },
                onToggleStyle: { fieldIndex in toggleStyle(fieldIndex, rowIndex: index) },
                onShift: { fieldIndex, delta in shift(fieldIndex, by: delta, rowIndex: index) },
                onRemove: { fieldIndex in remove(fieldIndex, rowIndex: index) })
                .listRowInsets(AgentListFieldsChrome.rowInsets)
                .agentListHostSurface(isFirst: false, isLast: false)
        }
    }

    private var slotsNote: some View {
        Text(HeaderLayoutCopy.rowSlots)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .listRowInsets(AgentListFieldsChrome.slotsNoteInsets)
            .listRowSeparator(.hidden)
            .agentListHostSurface(isFirst: false, isLast: true)
    }

    /// The editor's own notice cards (unreadable catalog, refused change),
    /// with the header screen's copy for the unreadable case.
    @ViewBuilder
    private var errorSection: some View {
        if editor.isCatalogUnreadable {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .accessibilityHidden(true)
                        Text(HeaderLayoutCopy.unreadableTitle)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                    }
                    Text(HeaderLayoutCopy.unreadableBody)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("settings.headerLayout.unreadable")
                    Button("Reset Header Layout", role: .destructive) {
                        editor.resetSavedFields()
                        store.resetUnreadable()
                        errorMessage = nil
                    }
                    .buttonStyle(.bordered)
                    .font(.subheadline.weight(.medium))
                    .padding(.top, 4)
                    .accessibilityIdentifier("settings.headerLayout.reset")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .listRowInsets(AgentListFieldsChrome.noticeInsets)
                .listRowSeparator(.hidden)
                .agentListHostSurface(isFirst: true, isLast: true)
            }
            .listSectionSeparator(.hidden)
        }
        if let message = errorMessage {
            Section {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundStyle(.red)
                        .accessibilityHidden(true)
                    Text(verbatim: message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("settings.headerLayout.error")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .listRowInsets(AgentListFieldsChrome.noticeInsets)
                .listRowSeparator(.hidden)
                .agentListHostSurface(isFirst: true, isLast: true)
            }
            .listSectionSeparator(.hidden)
        }
    }

    private func toggleStyle(_ fieldIndex: Int, rowIndex: Int) {
        AgentLayoutTokensEditing.setStyle(
            AgentLayoutTokensEditing.style(
                of: AgentLayoutTokensEditing.row(rowIndex, in: layout.rows)[fieldIndex]).toggled,
            at: fieldIndex, editor: editor, hostID: hostID, rowIndex: rowIndex)
    }

    private func shift(_ fieldIndex: Int, by delta: Int, rowIndex: Int) {
        AgentLayoutTokensEditing.shift(fieldIndex, by: delta, editor: editor, hostID: hostID, rowIndex: rowIndex)
    }

    private func remove(_ fieldIndex: Int, rowIndex: Int) {
        AgentLayoutTokensEditing.delete(
            IndexSet(integer: fieldIndex), editor: editor, hostID: hostID, rowIndex: rowIndex)
    }
}

/// Copy for the in-Agent header screen, kept beside the view that shows it.
enum HeaderLayoutCopy {
    static let intro =
        "The in-Agent header is the title area on the chat and terminal screens. "
        + "By default it shows the Host's Agent list fields (Settings → Agent list fields)."
    static let sameAsListCaption =
        "Follow the Agent list fields configured for each Host. Turn off to configure "
        + "a header layout of your own."
    static let rowSlots =
        "Row 1 shows above Row 2 in the header; Row 3 is Console's own row and is not "
        + "part of the header. Tap a field to change its style, move it, or remove it. "
        + "Tap + to add one. Changes save right away."
    static let previewHostName = "Workstation"
    static let unreadableTitle = "Saved header layout can’t be read"
    static let unreadableBody =
        "Heeler kept the saved data untouched. The header follows each Host's "
        + "Agent list fields, and editing is paused until you reset."
}
