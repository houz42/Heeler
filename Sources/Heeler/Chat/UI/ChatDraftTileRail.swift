import PhotosUI
import SwiftUI

// SPDX-License-Identifier: Apache-2.0
//
// §D draft tile rail (conversation redesign): the draft's attachments
// and quotes as SMALL SQUARE tiles in ONE line above the composer —
// corner x removes an individual draft item, tap opens the full
// preview/metadata, and a +N tile appears ONLY when real overflow
// exists, opening the collection sheet (every item listed, removable
// there). No item is ever silently dropped: what does not fit is
// behind +N.

/// One removable draft item the rail renders as a tile. The screen owns
/// the array; Send composes the message from it (attachment paths ride
/// ahead of the prose, quotes land block-quoted).
enum ChatDraftItem: Identifiable, Equatable {
    /// An uploaded image awaiting Send; previewData is the local
    /// thumbnail bytes (paste) or nil (picker, loads on demand).
    case image(id: String, remotePath: String, previewData: Data?)
    /// An uploaded file awaiting Send.
    case file(id: String, name: String, remotePath: String)
    /// A quoted message held as a removable draft item.
    case quote(id: String, text: String, author: String)

    var id: String {
        switch self {
        case .image(let id, _, _), .file(let id, _, _), .quote(let id, _, _):
            return id
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .image: return "Pending image attachment"
        case .file(_, let name, _): return "Pending file attachment \(name)"
        case .quote(_, let text, _):
            let line = text.prefix(40)
            return "Quoted message: \(line)"
        }
    }
}

/// Pure Send composition for the draft items + prose: every item rides
/// EXACTLY ONCE and the prose is preserved VERBATIM (attachment paths
/// never live in the prose — they are removed at tile-creation time,
/// so a user-typed path string can never be eaten here). Extracted so
/// the send contract is unit-testable.
enum ChatDraftComposer {
    static func messageText(items: [ChatDraftItem], draft: String) -> String {
        var parts: [String] = []
        // Quotes lead (the blockquoted context ahead of the reply —
        // the reading order), then the prose, then the @-references
        // (the user's contract: BOTH files and images reference as
        // @path — never a bare path).
        for item in items {
            if case .quote(_, let text, _) = item {
                parts.append(ChatQuote.draft(for: text))
            }
        }
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { parts.append(trimmed) }
        for item in items {
            switch item {
            case .image(_, let path, _), .file(_, _, let path):
                parts.append("@\(path)")
            case .quote:
                continue  // already led
            }
        }
        return parts.joined(separator: "\n")
    }
}

extension ChatDraftComposer {
    /// True when the composed message carries attachments — such a
    /// message is a PROMPT by definition and bypasses the router's
    /// prefix classification entirely (a trailing path reference must
    /// never be read as a shell command).
    static func carriesAttachments(items: [ChatDraftItem]) -> Bool {
        items.contains {
            if case .image = $0 { return true }
            if case .file = $0 { return true }
            return false
        }
    }
}

/// One square draft tile: content (thumbnail or type glyph) with a
/// corner-x remove button overlaying the top-trailing corner.
struct ChatDraftTile<Content: View>: View {
    let content: Content
    let remove: (() -> Void)?

    init(@ViewBuilder content: () -> Content, remove: (() -> Void)? = nil) {
        self.content = content()
        self.remove = remove
    }

    var body: some View {
        content
            .frame(width: 48, height: 48)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.secondary.opacity(0.3), lineWidth: 0.5))
            .overlay(alignment: .topTrailing) {
                if let remove {
                    // Fully INSIDE the tile's corner (the old +6/-6
                    // offset extended past the bounds and clipped at
                    // the rail's edge on device — the × was half
                    // hidden). 3pt padding keeps the whole hit target
                    // visible at every tile size.
                    Button(action: remove) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .background(Circle().fill(.bar))
                            .padding(3)
                    }
                    .accessibilityLabel("Remove draft item")
                }
            }
    }
}

/// The +N overflow tile: the count of tiles hidden by the width cap,
/// opening the collection sheet (every item listed, removable there).
struct ChatDraftTileOverflow: View {
    let hiddenCount: Int
    let total: Int
    let openCollection: () -> Void

    var body: some View {
        Button(action: openCollection) {
            Text("+\(hiddenCount)")
                .font(.footnote.weight(.medium))
                .frame(width: 48, height: 48)
                .background(
                    Color.secondary.opacity(0.1),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            "Show all \(total) draft items, \(hiddenCount) more")
    }
}

/// The one-line tile rail: width-responsive cap, ONE visual row. All
/// items render when they fit; the +N tile appears ONLY on real
/// overflow (count > fits) and takes the last fitting slot.
struct ChatDraftTileRail: View {
    var items: [ChatDraftItem]
    var removeItem: (String) -> Void
    var openPreview: (ChatDraftItem) -> Void
    var openCollection: () -> Void

    var body: some View {
        if !items.isEmpty {
            GeometryReader { geo in
                let fits = Self.fits(width: geo.size.width)
                // Overflow arithmetic: +N appears ONLY when the items
                // genuinely exceed the fitting tiles, and then occupies
                // one slot itself.
                let hasOverflow = items.count > fits
                // fits can be 0 at constrained widths; never negative.
                let visibleCount = hasOverflow ? max(fits - 1, 0) : items.count
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(items.prefix(visibleCount)) { item in
                            tileView(item)
                        }
                        if hasOverflow {
                            ChatDraftTileOverflow(
                                hiddenCount: items.count - visibleCount,
                                total: items.count,
                                openCollection: openCollection)
                        }
                    }
                }
            }
            .frame(height: 48)
        }
    }

    /// Boundary-correct: n tiles + (n-1) gaps fit the width — the
    /// unit is the tile+LEADING gap; the last tile needs no trailing
    /// gap. 2x48 + 8 = 104 fits exactly, floor(104/56)=1 is wrong.
    static func fits(width: CGFloat) -> Int {
        let tile: CGFloat = 48, gap: CGFloat = 8
        guard width >= tile else { return 0 }
        return Int((width + gap) / (tile + gap))
    }

    @ViewBuilder
    private func tileView(_ item: ChatDraftItem) -> some View {
        switch item {
        case .image(_, _, let previewData):
            ChatDraftTile(
                content: {
                    Group {
                        if let data = previewData,
                            let image = UIImage(data: data)
                        {
                            Image(uiImage: image).resizable().scaledToFill()
                        } else {
                            Image(systemName: "photo").font(.title3)
                        }
                    }
                },
                remove: { removeItem(item.id) })
                .onTapGesture { openPreview(item) }
                .accessibilityLabel(item.accessibilityLabel)
        case .file(_, let name, _):
            ChatDraftTile(
                content: {
                    VStack(spacing: 2) {
                        Image(systemName: "doc")
                            .font(.subheadline)
                        Text(name)
                            .font(.system(size: 7))
                            .lineLimit(1)
                            .frame(maxWidth: 40)
                    }
                },
                remove: { removeItem(item.id) })
                .accessibilityLabel(item.accessibilityLabel)
        case .quote(_, let text, let author):
            ChatDraftTile(
                content: {
                    VStack(spacing: 2) {
                        Image(systemName: "text.quote")
                            .font(.subheadline)
                        Text(author)
                            .font(.system(size: 7))
                            .lineLimit(1)
                            .frame(maxWidth: 40)
                            .foregroundStyle(.secondary)
                    }
                },
                remove: { removeItem(item.id) })
                .onTapGesture { openPreview(item) }
                .accessibilityLabel(item.accessibilityLabel)
        }
    }
}

/// The +N collection sheet: EVERY draft item listed full-width with
/// its preview text/thumbnail and a remove action — nothing is
/// reachable only from the rail's visible slice.
struct ChatDraftCollectionSheet: View {
    var items: [ChatDraftItem]
    var removeItem: (String) -> Void
    var openPreview: (ChatDraftItem) -> Void

    var body: some View {
        NavigationStack {
            List {
                ForEach(items) { item in
                    Button {
                        openPreview(item)
                    } label: {
                        row(item)
                    }
                    .buttonStyle(.plain)
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            removeItem(item.id)
                        } label: {
                            Label("Remove", systemImage: "trash")
                        }
                    }
                }
            }
            .navigationTitle("Draft items")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    @ViewBuilder
    private func row(_ item: ChatDraftItem) -> some View {
        switch item {
        case .image(_, _, let previewData):
            HStack(spacing: 12) {
                Group {
                    if let data = previewData,
                        let image = UIImage(data: data)
                    {
                        Image(uiImage: image).resizable().scaledToFill()
                    } else {
                        Image(systemName: "photo")
                    }
                }
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                Text("Image attachment")
            }
        case .file(_, let name, _):
            HStack(spacing: 12) {
                Image(systemName: "doc")
                    .frame(width: 44, height: 44)
                Text(name).lineLimit(2)
            }
        case .quote(_, let text, let author):
            VStack(alignment: .leading, spacing: 4) {
                Text(author).font(.caption).foregroundStyle(.secondary)
                Text(text).font(.subheadline).lineLimit(3)
            }
        }
    }
}

/// The tapped draft tile's full preview: an image zooms and pans; a
/// quote shows its full text with the author; a file shows its name
/// and remote path (the in-app reader for real files rides the
/// openers' fetch surface).
struct ChatDraftItemPreview: View {
    let item: ChatDraftItem
    /// Reads the file's bytes (the host read seam) for the in-app
    /// reader; nil = honest unavailable.
    var fileFetch: RemoteFileFetcher? = nil

    var body: some View {
        NavigationStack {
            Group {
                switch item {
                case .image(_, _, let previewData):
                    if let data = previewData, let image = UIImage(data: data) {
                        ZoomableImageView(image: image)
                    } else {
                        ContentUnavailableView(
                            "Image attachment",
                            systemImage: "photo",
                            description: Text(
                                "The thumbnail is not cached; it uploads with the message."))
                    }
                case .file(_, let name, let path):
                    ChatDraftFileReader(name: name, path: path, fetch: fileFetch)
                case .quote(_, let text, let author):
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(author)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Text(text)
                                .font(.body)
                                .textSelection(.enabled)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                    }
                }
            }
            .navigationTitle("Draft item")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

/// Pinch-zoom and pan for the image preview.
struct ZoomableImageView: View {
    let image: UIImage
    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    var body: some View {
        Image(uiImage: image)
            .resizable()
            .scaledToFit()
            .scaleEffect(scale)
            .offset(offset)
            .gesture(
                MagnificationGesture()
                    .onChanged { value in
                        scale = max(1, lastScale * value)
                    }
                    .onEnded { _ in
                        lastScale = scale
                        if scale <= 1 {
                            withAnimation(.snappy) {
                                scale = 1
                                offset = .zero
                                lastOffset = .zero
                            }
                            lastScale = 1
                        }
                    })
            .simultaneousGesture(
                DragGesture()
                    .onChanged { value in
                        guard scale > 1 else { return }
                        offset = CGSize(
                            width: lastOffset.width + value.translation.width,
                            height: lastOffset.height + value.translation.height)
                    }
                    .onEnded { _ in
                        lastOffset = offset
                    })
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(.systemBackground))
            .onTapGesture(count: 2) {
                withAnimation(.snappy) {
                    scale = scale > 1 ? 1 : 2.5
                    lastScale = scale > 1 ? 2.5 : 1
                    offset = .zero
                    lastOffset = .zero
                }
            }
            .accessibilityLabel("Image preview, pinch to zoom")
    }
}


/// The in-app reader for a draft file attachment: loads the file's
/// bytes through the host read seam and renders them read-only
/// (monospaced, selectable). No seam or a failed read = an HONEST
/// unavailable state, never a fake empty document.
struct ChatDraftFileReader: View {
    let name: String
    let path: String
    var fetch: RemoteFileFetcher?

    @State private var contents: String?
    @State private var failed = false

    var body: some View {
        Group {
            if let contents {
                ScrollView {
                    Text(contents)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                }
            } else if failed {
                ContentUnavailableView(
                    "File unavailable",
                    systemImage: "doc.badge.ellipsis",
                    description: Text(
                        "The file could not be read from the host (\(path))."))
            } else {
                ProgressView("Reading file…")
            }
        }
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard let fetch else {
                failed = true
                return
            }
            do {
                let data = try await fetch(path)
                contents = String(data: data, encoding: .utf8)
                    ?? "[binary file, \(data.count) bytes]"
                if contents?.isEmpty == true {
                    contents = "[empty file]"
                }
            } catch {
                failed = true
            }
        }
    }
}
