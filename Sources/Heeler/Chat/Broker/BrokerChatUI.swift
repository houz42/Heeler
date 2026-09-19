import SwiftUI

// SPDX-License-Identifier: Apache-2.0
//
// The broker chat backend's honest state surfaces: a banner for
// connecting/error/disconnected/ambiguous states, and the unsupported
// ask card (native ask answering has NO verified public API in v1 — the
// card says so instead of faking a delivery path).

/// One compact state card pinned above the chat content.
struct BrokerChatStateBanner: View {
    let icon: String
    let title: String
    let detail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: icon)
                .font(.headline)
            if let detail {
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 12))
        .padding(16)
        .accessibilityElement(children: .combine)
    }
}

/// The ask card for broker-backed panes: the question renders, but the
/// answer affordance is an honest unsupported state — no buttons that
/// pretend to deliver, no keystroke fallback. The user answers in the
/// agent's own terminal surface, which the banner says plainly.
struct BrokerUnsupportedAskRow: View {
    let interaction: PendingInteraction

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Waiting for your answer", systemImage: "questionmark.circle")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.orange)
            ChatBlockText(interaction.question, style: .assistant)
            Label(
                "Answering is not supported yet — reply from the agent's terminal.",
                systemImage: "lock.slash"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }
}
