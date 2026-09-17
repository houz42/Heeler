import SafariServices
import SwiftUI

// SPDX-License-Identifier: Apache-2.0
//
// The UIKit/Safari surfaces for chat link opens: one view modifier that
// interprets an `OpenRouterCore`'s published state (SFSafari embedded, ask
// sheet, markdown viewer, share flow, failure alert). ChatScreen applies
// it; the pure core in OpenRouter.swift stays testable without UIKit.

/// The pane-side presentation for one `OpenRouterCore`: presents whatever
/// the router holds, and forwards default-browser opens out to the pane's
/// `\.openURL`. Applied as one modifier so the ChatScreen call site stays
/// a single wrap.
/// A `URL` boxed for `sheet(item:)` (URL is not Identifiable).
struct PresentedLink: Identifiable, Equatable {
    let url: URL
    var id: String { url.absoluteString }
}

struct OpenersPresenter: ViewModifier {
    @ObservedObject var router: OpenRouterCore

    /// The URL SFSafariViewController is currently showing (set from the
    /// router's read-only `browsing`; nil dismisses).
    @State private var safariLink: PresentedLink?

    func body(content: Content) -> some View {
        content
            .onChange(of: router.browsing) { _, url in
                safariLink = url.map { PresentedLink(url: $0) }
            }
            .sheet(item: $safariLink) { link in
                SafariView(url: link.url)
                    .ignoresSafeArea(edges: .bottom)
            }
            .sheet(item: markdownBinding) { document in
                MarkdownViewerView(router: router, document: document)
            }
            .sheet(item: shareBinding) { target in
                RemoteShareFlow(
                    target: target, fetch: router.fetch, router: router)
                    .presentationDetents([.medium])
            }
            .sheet(item: askBinding) { link in
                EmbeddedBrowseAskSheet(url: link.url) { embedded in
                    if embedded {
                        router.resolveBrowse(url: link.url, embedded: true)
                    } else {
                        router.cancelBrowseAsk()
                    }
                }
            }
            .alert(
                "Couldn't Open",
                isPresented: plainRefusalBinding,
                presenting: router.refusal
            ) { _ in
                Button("OK") { router.clearRefusal() }
            } message: { reason in
                Text(reason)
            }
    }

    /// The markdown sheet's binding over the router's read-only state:
    /// setting nil dismisses through the router.
    private var markdownBinding: Binding<MarkdownDocument?> {
        Binding(
            get: { router.markdown },
            set: { newValue in
                if newValue == nil, router.markdown != nil {
                    router.dismissMarkdown()
                }
            }
        )
    }

    /// The share sheet's binding, same read-only pattern.
    private var shareBinding: Binding<RemoteShareTarget?> {
        Binding(
            get: { router.shareTarget },
            set: { newValue in
                if newValue == nil, router.shareTarget != nil {
                    router.dismissShareTarget()
                }
            }
        )
    }

    /// The ask sheet's binding lifts only the ask case out of the router.
    private var askBinding: Binding<PresentedLink?> {
        Binding(
            get: { router.ask.map { PresentedLink(url: $0) } },
            set: { newValue in
                if newValue == nil, router.ask != nil {
                    router.cancelBrowseAsk()
                }
            }
        )
    }

    /// The alert's binding lifts only the refusal case.
    private var plainRefusalBinding: Binding<Bool> {
        Binding(
            get: { router.refusal != nil },
            set: { newValue in
                if !newValue, router.refusal != nil {
                    router.clearRefusal()
                }
            }
        )
    }
}

/// The embedded-vs-default-browser decision sheet for a first-seen domain.
/// "Open Here" persists the allow and shows Safari embedded; the plain
/// browser buttons route to the default browser without persisting a
/// refusal — the next tap asks again.
struct EmbeddedBrowseAskSheet: View {
    let url: URL
    /// Called with the user's embedded choice. A `false` that arrives from
    /// "Default Browser" does NOT persist (cancel semantics keep asking).
    let choose: (_ embedded: Bool) -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Image(systemName: "safari")
                    .font(.system(size: 36))
                    .foregroundStyle(.tint)
                Text(url.host ?? url.absoluteString)
                    .font(.headline)
                    .multilineTextAlignment(.center)
                Text("How should links to this site open?")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                VStack(spacing: 10) {
                    Button {
                        choose(true)
                    } label: {
                        Label("Open Here", systemImage: "safari")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    Button {
                        choose(false)
                    } label: {
                        Label("Default Browser", systemImage: "arrow.up.forward.app")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
                .padding(.horizontal, 24)
                Text(
                    "\"Open Here\" is remembered for this site; the default-browser choice asks again next time."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
                Spacer()
            }
            .padding(.top, 32)
            .navigationTitle("Open Link")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { choose(false) }
                }
            }
        }
        .presentationDetents([.medium])
    }
}

/// SFSafariViewController embedded in the pane (reached only when the
/// per-domain allowlist stored an allow decision).
struct SafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let configuration = SFSafariViewController.Configuration()
        configuration.entersReaderIfAvailable = false
        return SFSafariViewController(url: url, configuration: configuration)
    }

    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}
