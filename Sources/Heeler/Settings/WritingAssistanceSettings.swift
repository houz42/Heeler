import Foundation
import Observation
import SwiftUI

// SPDX-License-Identifier: Apache-2.0
//
// The chat writing-assistance preference (v3 design doc, "Writing
// assistance and placeholder restoration"): ordinary Chat DEFAULTS to
// the system keyboard's own spelling correction/prediction, following
// the OS language and keyboard. Settings → Chat → Writing assistance
// provides System/Off. No second predictive engine, no drafts sent to
// a new service, and no promise of control over third-party keyboards
// (a custom keyboard runs its own prediction regardless of our text
// traits).

/// The writing-assistance choice for the ordinary chat field.
enum WritingAssistance: String, CaseIterable, Identifiable, Sendable {
    /// Follow the system keyboard's own correction/prediction (the
    /// default). The DEFAULT multilingual OS keyboard presents, with
    /// its language/globe and dismissal controls.
    case system
    /// Disable correction/prediction on the chat field and pin the
    /// ASCII-capable keyboard (literal typing).
    case off

    var id: Self { self }

    var title: String {
        switch self {
        case .system: "System"
        case .off: "Off"
        }
    }
}

/// The persisted choice. Dedicated command/path/shell editors (the
/// + menu's choosers, terminal input) ALWAYS stay literal regardless
/// of this setting — the design doc's rule; only the ordinary chat
/// field follows it.
@MainActor
@Observable
final class WritingAssistanceSettings {
    private static let defaultsKey = "chat-writing-assistance"

    private(set) var selection: WritingAssistance
    @ObservationIgnored private nonisolated(unsafe) let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        selection =
            defaults.string(forKey: Self.defaultsKey)
            .flatMap(WritingAssistance.init(rawValue:)) ?? .system
    }

    /// The process-wide instance the chat surfaces and Settings share.
    static let shared = WritingAssistanceSettings()

    /// True when the ordinary chat field follows the system keyboard's
    /// own correction/prediction (System); false disables it (Off).
    var isEnabled: Bool { selection == .system }

    func select(_ choice: WritingAssistance) {
        guard choice != selection else { return }
        selection = choice
        defaults.set(choice.rawValue, forKey: Self.defaultsKey)
    }
}

/// Settings → Chat → Writing assistance: System (follow the OS
/// keyboard's own correction/prediction — the default) or Off (literal
/// chat field). Dedicated command/path/shell editors are always
/// literal regardless of this choice.
struct WritingAssistanceSettingsView: View {
    @Bindable var settings: WritingAssistanceSettings

    var body: some View {
        Form {
            Section {
                Picker("Writing Assistance", selection: Binding(
                    get: { settings.selection },
                    set: { settings.select($0) })
                ) {
                    ForEach(WritingAssistance.allCases) { choice in
                        Text(choice.title).tag(choice)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } footer: {
                Text(
                    "System follows your keyboard’s own correction and "
                        + "prediction. Off makes the message field literal. "
                        + "Command, path, and shell fields are always "
                        + "literal. Third-party keyboards control their own "
                        + "prediction.")
            }
        }
        .navigationTitle("Writing Assistance")
        .navigationBarTitleDisplayMode(.inline)
    }
}
