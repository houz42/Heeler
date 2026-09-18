import SwiftUI

// SPDX-License-Identifier: Apache-2.0
//
// The internal markdown viewer: minimal chrome, monospace scrollable text.
// MarkdownUI is now a project dependency (chat rendering), but this
// viewer keeps the plain-monospace v1 body: fetched files can be huge,
// and Markdown-style rendering of arbitrary 10MB transcripts is not a
// trade this surface needs yet. Adopting it later is a body-local change.

/// Full-screen markdown document viewer for one fetched remote file.
/// Minimal chrome: a thin inline header (title, Done, actions menu) and
/// scrollable monospace content.
struct MarkdownViewerView: View {
    static let tooLargeMessage = String(
        localized: "This file is too large to open silently (over 10 MB).")

    let router: OpenRouterCore
    let document: MarkdownDocument

    @State private var showShareSheet = false

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(document.contents)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
            .background(.background)
            .navigationTitle(document.fileName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        router.dismissMarkdown()
                    }
                    .accessibilityLabel("Close document viewer")
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button {
                            UIPasteboard.general.string = document.contents
                        } label: {
                            Label("Copy Contents", systemImage: "doc.on.doc")
                        }
                        Button {
                            showShareSheet = true
                        } label: {
                            Label("Share…", systemImage: "square.and.arrow.up")
                        }
                    } label: {
                        Label("More", systemImage: "ellipsis.circle")
                    }
                    .accessibilityLabel("Document actions")
                }
            }
            .sheet(isPresented: $showShareSheet) {
                ShareSheet(items: [document.contents])
            }
        }
    }
}
