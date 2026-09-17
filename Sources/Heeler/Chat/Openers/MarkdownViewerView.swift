import SwiftUI

// SPDX-License-Identifier: Apache-2.0
//
// The internal markdown viewer: minimal chrome, monospace scrollable text
// (swift-markdown is not a dependency of this project — checked
// Package.resolved — so v1 renders plain monospace text; adopting the
// package later is a body-local change). Close plus the open-external
// affordances (copy, share out) are the whole chrome.

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
