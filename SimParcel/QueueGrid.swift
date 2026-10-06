import QuickLookThumbnailing
import SwiftUI

struct QueueGrid: View {
    @Environment(AppModel.self) private var model

    private let columns = [GridItem(.adaptive(minimum: 112, maximum: 150), spacing: 14)]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(summary)
                    .font(.headline)

                if model.failedCount > 0 {
                    Text("\(model.failedCount) failed")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(.red, in: Capsule())
                }

                Spacer()

                Button("Clear All", role: .destructive) {
                    withAnimation {
                        model.removeAll()
                    }
                }
                .buttonStyle(.borderless)
                .disabled(model.isSending)
            }
            .padding(.horizontal, 20)
            .padding(.top, 14)
            .padding(.bottom, 6)

            ScrollView {
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(model.items) { item in
                        QueueTile(item: item, isSending: model.sendingItemID == item.id)
                            .transition(.scale(scale: 0.8).combined(with: .opacity))
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .animation(.spring(duration: 0.3), value: model.items.map(\.id))
            }
        }
    }

    private var summary: String {
        let count = model.items.count
        return count == 1 ? "1 item" : "\(count) items"
    }
}

private struct QueueTile: View {
    @Environment(AppModel.self) private var model
    @State private var isHovered = false

    let item: QueueItem
    let isSending: Bool

    var body: some View {
        VStack(spacing: 6) {
            Thumbnail(item: item)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(item.failure == nil ? AnyShapeStyle(.separator) : AnyShapeStyle(.red), lineWidth: item.failure == nil ? 0.5 : 2)
                }
                .overlay(alignment: .bottomLeading) {
                    if let badge = item.kind.badge {
                        Label(badge.title, systemImage: badge.symbol)
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(.ultraThinMaterial, in: Capsule())
                            .padding(6)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if isHovered && !model.isSending {
                        removeButton
                            .padding(5)
                            .transition(.opacity)
                    }
                }
                .overlay(alignment: .topLeading) {
                    if item.failure != nil {
                        Image(systemName: "exclamationmark.circle.fill")
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .red)
                            .font(.title3)
                            .padding(5)
                    }
                }
                .overlay(alignment: .center) {
                    if let itemFailure = item.failure,
                        let recognizedFailure = model.parseFailure(itemFailure) {
                        Text(recognizedFailure)
                            .foregroundStyle(.red)
                            .font(.headline)
                            .padding(5)
                    }
                }
                .overlay {
                    if isSending {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(.regularMaterial)
                            .overlay {
                                ProgressView()
                                    .controlSize(.small)
                            }
                    }
                }
                .shadow(color: .black.opacity(0.08), radius: 3, y: 1)

            Text(item.name)
                .font(.caption)
                .foregroundStyle(item.failure == nil ? .primary : Color.red)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) {
                isHovered = hovering
            }
        }
        .help(item.failure.map { "Failed: \($0)" } ?? item.urls.map(\.displayPath).joined(separator: "\n"))
        .contextMenu {
            if item.kind == .link {
                Button("Copy Link") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(item.name, forType: .string)
                }
            } else {
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting(item.urls)
                }
            }

            Divider()

            Button("Remove", role: .destructive) {
                model.remove(item)
            }
            .disabled(model.isSending)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAction(named: "Remove") {
            model.remove(item)
        }
    }

    private var removeButton: some View {
        Button {
            model.remove(item)
        } label: {
            Image(systemName: "xmark.circle.fill")
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, .black.opacity(0.55))
                .font(.title3)
        }
        .buttonStyle(.plain)
        .help("Remove from queue")
    }

    private var accessibilityLabel: String {
        let label = "\(item.kind.title), \(item.name)"
        return item.failure.map { "\(label), failed: \($0)" } ?? label
    }
}

private struct Thumbnail: View {
    let item: QueueItem
    @State private var image: NSImage?

    var body: some View {
        // The square container defines the size; the content fills or fits it and never widens the tile.
        Rectangle()
            .fill(background)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                switch item.kind {
                case .push, .link:
                    symbol
                case .photo, .video, .livePhoto:
                    if let image {
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFill()
                            .transition(.opacity)
                    } else {
                        placeholder
                    }
                case .contact, .app, .file:
                    if let image {
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFit()
                            .padding(18)
                            .transition(.opacity)
                    } else {
                        placeholder
                    }
                }
            }
            .clipped()
            .task(id: item.previewURL) {
                guard item.previewURL.isFileURL else {
                    return
                }
                image = await Self.thumbnail(for: item.previewURL)
            }
    }

    private var background: AnyShapeStyle {
        switch item.kind {
        case .push, .link:
            AnyShapeStyle(.tint.opacity(0.12))
        default:
            AnyShapeStyle(.quaternary)
        }
    }

    private var symbol: some View {
        VStack(spacing: 6) {
            Image(systemName: item.kind == .push ? "bell.badge.fill" : "link")
                .font(.system(size: 34, weight: .medium))
                .foregroundStyle(.tint)

            if item.kind == .link, let host = item.urls.first?.host() ?? item.urls.first?.scheme {
                Text(host)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.horizontal, 8)
            }
        }
    }

    private var placeholder: some View {
        Image(systemName: "photo")
            .font(.title)
            .foregroundStyle(.tertiary)
    }

    private static func thumbnail(for file: URL) async -> NSImage? {
        let request = QLThumbnailGenerator.Request(
            fileAt: file,
            size: CGSize(width: 150, height: 150),
            scale: NSScreen.main?.backingScaleFactor ?? 2,
            representationTypes: .thumbnail
        )

        guard let cgImage = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).cgImage else {
            return NSWorkspace.shared.icon(forFile: file.path)
        }

        return NSImage(cgImage: cgImage, size: .zero)
    }
}

private extension ItemKind {
    var badge: (title: String, symbol: String)? {
        switch self {
        case .photo: nil
        case .video: ("Video", "video.fill")
        case .livePhoto: ("Live", "livephoto")
        case .contact: ("Contact", "person.crop.circle")
        case .app: ("App", "app.badge")
        case .push: ("Push", "bell.fill")
        case .link: ("Link", "link")
        case .file: ("Files", "folder.fill")
        }
    }
}

private extension URL {
    var displayPath: String {
        isFileURL ? path : absoluteString
    }
}
