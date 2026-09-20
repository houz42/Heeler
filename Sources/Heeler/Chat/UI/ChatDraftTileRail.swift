import PhotosUI
import SwiftUI

// SPDX-License-Identifier: Apache-2.0
//
// §D draft tile rail (conversation redesign): the draft's attachments
// and quotes as SMALL SQUARE tiles in ONE line above the composer —
// corner x removes an individual draft item, tap opens the full
// preview/metadata, a final +N tile collects overflow responsively
// (no growing second row; every item preserved, not just visible ones).
//
// Model consumption: the single pending-image attachment from
// ChatAttachmentDraftStore (imported verbatim from the attachments
// lane). The multi-attachment items[] + structured quote tiles are
// the approved model extension (routed through Main at integration);
// the rail's layout is built for it — tiles flow through the same
// wrapping layout and overflow counter either way.

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
                    Button(action: remove) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .background(Circle().fill(.bar))
                    }
                    .offset(x: 6, y: -6)
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

/// The one-line tile rail: wrapping layout with the width-responsive
/// +N cap. The wrapping keeps ONE visual row line-height (the design
/// forbids a growing second row) by capping visible tiles to what fits
/// and collecting the rest behind +N.
struct ChatDraftTileRail: View {
    /// The pending image tile data (nil = no image in the draft).
    var imagePreviewData: Data?
    /// Quotes carried as draft items (each tile shows a quote glyph).
    var quoteCount: Int = 0
    /// Opens the tapped image's full preview.
    var openImagePreview: () -> Void
    /// Removes the image from the draft.
    var removeImage: (() -> Void)?

    var body: some View {
        let tiles = tileIdentifiers
        if tiles.isEmpty { EmptyView() } else {
            GeometryReader { geo in
                let slots = max(visibleSlots(width: geo.size.width, count: tiles.count), 1)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
        // The design's responsive cap: slots-1 tiles visible, then +N.
                        ForEach(Array(tiles.prefix(slots - 1).enumerated()), id: \.element) { _, tile in
                            tileView(tile)
                        }
                        if tiles.count > slots - 1 {
                            ChatDraftTileOverflow(
                                hiddenCount: tiles.count - (slots - 1),
                                total: tiles.count) {
                                // The collection sheet lands with the
                                // multi-attachment model extension; the
                                // +N is honest (disabled) meanwhile.
                                openCollectionStub()
                            }
                            .disabled(true)
                        }
                    }
                }
            }
            .frame(height: 48)
        }
    }

    private var tileIdentifiers: [String] {
        var ids: [String] = []
        if imagePreviewData != nil { ids.append("image") }
        ids.append(contentsOf: (0..<quoteCount).map { "quote-\($0)" })
        return ids
    }

    @ViewBuilder
    private func tileView(_ id: String) -> some View {
        if id == "image" {
            ChatDraftTile(
                content: {
                    Group {
                        if let data = imagePreviewData,
                            let image = UIImage(data: data)
                        {
                            Image(uiImage: image).resizable().scaledToFill()
                        } else {
                            Image(systemName: "photo").font(.title3)
                        }
                    }
                },
                remove: removeImage)
                .onTapGesture(perform: openImagePreview)
        } else if id.hasPrefix("quote-") {
            ChatDraftTile(
                content: {
                    VStack(spacing: 2) {
                        Image(systemName: "text.quote")
                            .font(.subheadline)
                    }
                },
                remove: nil)
        }
    }

    /// Visible tile count from the width: floor(width / (tile + spacing)),
    /// leaving one slot for the +N tile when overflow exists.
    private func visibleSlots(width: CGFloat, count: Int) -> Int {
        let unit: CGFloat = 48 + 8
        let fits = Int(width / unit)
        return min(fits, count + 1)
    }

    private func openCollectionStub() {}
}
