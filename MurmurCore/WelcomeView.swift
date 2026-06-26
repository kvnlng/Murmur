//
//  WelcomeView.swift
//  Murmur
//
//  First-launch experience. A centered card on a faint ECG-paper backdrop
//  invites the analyst to open a WFDB folder, try a sample, or visit
//  PhysioNet for example data. ContentView swaps this view into the
//  `.empty` state instead of the bare icon-and-button stub.
//
//  Accessibility identifiers `empty-state-prompt` and
//  `empty-state-open-button` are intentionally preserved here so the
//  existing UI tests continue to find the welcome card.
//

import SwiftUI

struct WelcomeView: View {
    /// Invoked when the user taps the primary "Open Record Folder" action.
    let onOpenFolder: () -> Void
    /// Optional secondary action. When `nil`, the button is hidden — used to
    /// hide the affordance in builds where the synthetic fixture isn't
    /// available.
    let onTrySample: (() -> Void)?
    /// Recently opened folders, newest first. Empty hides the section.
    var recents: [RecentFolder] = []
    /// Invoked when the user clicks a row in the recents list.
    var onPickRecent: ((RecentFolder) -> Void)? = nil
    /// Invoked when the user removes a row from the recents list.
    var onRemoveRecent: ((RecentFolder) -> Void)? = nil
    /// Invoked when the user drops a folder anywhere on the welcome view.
    /// Receives the dropped URL (or, if the user dropped a file by mistake,
    /// the URL of its enclosing folder).
    var onDropFolder: ((URL) -> Void)? = nil

    @State private var isDropTargeted = false

    var body: some View {
        ZStack {
            ECGPaperBackdrop()
                .ignoresSafeArea()

            Color.accentColor
                .opacity(isDropTargeted ? 0.10 : 0)
                .ignoresSafeArea()
                .animation(.easeOut(duration: 0.15), value: isDropTargeted)

            ScrollView {
                HStack(alignment: .top) {
                    Spacer(minLength: 24)
                    VStack(spacing: 20) {
                        card
                        if !recents.isEmpty {
                            recentsSection
                        }
                    }
                    .frame(maxWidth: 560)
                    Spacer(minLength: 24)
                }
                .padding(.vertical, 32)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .modifier(FolderDropTarget(
            onDrop: onDropFolder,
            isTargeted: $isDropTargeted
        ))
    }

    // MARK: - Card

    private var card: some View {
        VStack(alignment: .leading, spacing: 24) {
            header
            featureList
            actionStack
            Divider()
            physioNetFooter
        }
        .padding(.horizontal, 36)
        .padding(.vertical, 32)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground)
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(.background)
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.12), radius: 24, x: 0, y: 8)
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 14) {
                Image(systemName: "waveform.path.ecg")
                    .font(.system(size: 40, weight: .regular))
                    .foregroundStyle(Color.accentColor)
                    .accessibilityHidden(true)
                Text("Murmur")
                    .font(.system(size: 38, weight: .semibold, design: .rounded))
            }
            Text("WFDB ECG viewer for analyst review of clinical findings.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("empty-state-prompt")
        }
    }

    // MARK: - Feature bullets

    private var featureList: some View {
        VStack(alignment: .leading, spacing: 14) {
            bullet(
                icon: "folder",
                title: "Open a WFDB record",
                detail: "Pick a folder of .hea + .dat files — formats 16 and 212 ingest out of the box."
            )
            bullet(
                icon: "list.bullet.clipboard",
                title: "Review findings in context",
                detail: "Overlay your analysis cluster's annotations on the trace, filtered by category, severity, and confidence."
            )
            bullet(
                icon: "rectangle.expand.diagonal",
                title: "Scrub a Metal canvas",
                detail: "Pan, zoom, and time-lock every lead on a pyramid-backed canvas that stays smooth at any duration."
            )
        }
    }

    @ViewBuilder
    private func bullet(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(Color.accentColor)
                .frame(width: 28, alignment: .center)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body.weight(.semibold))
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Actions

    private var actionStack: some View {
        VStack(spacing: 10) {
            Button(action: onOpenFolder) {
                Label("Open Record Folder", systemImage: "folder.badge.plus")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .accessibilityIdentifier("empty-state-open-button")

            if let onTrySample {
                Button(action: onTrySample) {
                    Label("Try a sample recording", systemImage: "play.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .accessibilityIdentifier("welcome-try-sample-button")
            }

            if onDropFolder != nil {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.down.doc")
                        .font(.caption)
                    Text("Or drag a folder onto this window")
                        .font(.caption)
                }
                .foregroundStyle(.tertiary)
                .padding(.top, 4)
            }
        }
    }

    // MARK: - Recents

    @ViewBuilder
    private var recentsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Recent")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
            VStack(spacing: 0) {
                ForEach(Array(recents.enumerated()), id: \.element.id) { idx, entry in
                    RecentFolderRow(
                        entry: entry,
                        onPick: { onPickRecent?(entry) },
                        onRemove: onRemoveRecent.map { remove in { remove(entry) } }
                    )
                    if idx < recents.count - 1 {
                        Divider()
                    }
                }
            }
            .background(cardBackground)
        }
        .accessibilityIdentifier("welcome-recents")
    }

    // MARK: - Footer

    private var physioNetFooter: some View {
        HStack(spacing: 4) {
            Text("Need data?")
                .foregroundStyle(.secondary)
            Link(
                "Browse PhysioNet's MIT-BIH Arrhythmia Database",
                destination: URL(string: "https://www.physionet.org/content/mitdb/1.0.0/")!
            )
            .accessibilityIdentifier("welcome-physionet-link")
        }
        .font(.footnote)
    }
}

// MARK: - Folder drop target

/// Accepts dropped folders (or a file's enclosing folder as a courtesy) and
/// forwards a single URL to the welcome view. Acts as a no-op when no drop
/// handler is wired so the modifier can be applied unconditionally.
private struct FolderDropTarget: ViewModifier {
    let onDrop: ((URL) -> Void)?
    @Binding var isTargeted: Bool

    func body(content: Content) -> some View {
        if let onDrop {
            content
                .dropDestination(for: URL.self) { urls, _ in
                    guard let url = urls.first else { return false }
                    let folder = Self.resolveFolder(for: url)
                    onDrop(folder)
                    return true
                } isTargeted: { hovering in
                    isTargeted = hovering
                }
        } else {
            content
        }
    }

    /// Returns `url` itself when it points to a directory, otherwise the
    /// directory containing the file. Lets the user drop either a folder or
    /// a `.hea` (or anything else inside the record folder) and still land
    /// at the right place.
    private static func resolveFolder(for url: URL) -> URL {
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        if exists, isDir.boolValue {
            return url
        }
        return url.deletingLastPathComponent()
    }
}

// MARK: - Recent folder row

private struct RecentFolderRow: View {
    let entry: RecentFolder
    let onPick: () -> Void
    let onRemove: (() -> Void)?

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onPick) {
                HStack(spacing: 12) {
                    Image(systemName: "folder")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .frame(width: 22)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(entry.displayName)
                            .font(.body)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(entry.resolvedPath)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer()
                    Text(entry.addedAt.formatted(.relative(presentation: .named)))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Forget this folder")
                .accessibilityLabel("Forget \(entry.displayName)")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .accessibilityIdentifier("welcome-recent-\(entry.displayName)")
    }
}

// MARK: - ECG paper backdrop

/// Faint full-screen ECG paper texture that sets the visual tone behind the
/// welcome card. Colors mirror `WaveformStyle` so the backdrop reads as the
/// same paper the analyst will see in the bedside view, just dialed down.
private struct ECGPaperBackdrop: View {
    private static let minorSpacing: CGFloat = 8
    private static let majorMultiple: Int = 5

    var body: some View {
        Canvas { ctx, size in
            paint(ctx: ctx, size: size)
        }
        .opacity(0.55)
    }

    private func paint(ctx: GraphicsContext, size: CGSize) {
        let paperColor = Color(red: 1.00, green: 0.95, blue: 0.95)
        let minorColor = Color(red: 0.93, green: 0.78, blue: 0.78).opacity(0.50)
        let majorColor = Color(red: 0.82, green: 0.50, blue: 0.50).opacity(0.55)

        ctx.fill(
            Path(CGRect(origin: .zero, size: size)),
            with: .color(paperColor)
        )

        let minor = Self.minorSpacing
        let major = minor * CGFloat(Self.majorMultiple)

        // Minor grid
        drawVerticalLines(ctx: ctx, size: size, spacing: minor, color: minorColor, width: 0.5)
        drawHorizontalLines(ctx: ctx, size: size, spacing: minor, color: minorColor, width: 0.5)
        // Major grid sits on top.
        drawVerticalLines(ctx: ctx, size: size, spacing: major, color: majorColor, width: 0.9)
        drawHorizontalLines(ctx: ctx, size: size, spacing: major, color: majorColor, width: 0.9)
    }

    private func drawVerticalLines(
        ctx: GraphicsContext,
        size: CGSize,
        spacing: CGFloat,
        color: Color,
        width: CGFloat
    ) {
        var x: CGFloat = 0
        while x <= size.width {
            ctx.stroke(
                Path { p in
                    p.move(to: CGPoint(x: x, y: 0))
                    p.addLine(to: CGPoint(x: x, y: size.height))
                },
                with: .color(color),
                lineWidth: width
            )
            x += spacing
        }
    }

    private func drawHorizontalLines(
        ctx: GraphicsContext,
        size: CGSize,
        spacing: CGFloat,
        color: Color,
        width: CGFloat
    ) {
        var y: CGFloat = 0
        while y <= size.height {
            ctx.stroke(
                Path { p in
                    p.move(to: CGPoint(x: 0, y: y))
                    p.addLine(to: CGPoint(x: size.width, y: y))
                },
                with: .color(color),
                lineWidth: width
            )
            y += spacing
        }
    }
}

#Preview("Welcome - no recents") {
    WelcomeView(
        onOpenFolder: {},
        onTrySample: {}
    )
    .frame(width: 900, height: 700)
}

#Preview("Welcome - with recents") {
    WelcomeView(
        onOpenFolder: {},
        onTrySample: {},
        recents: [
            RecentFolder(
                id: UUID(),
                displayName: "mit-bih",
                resolvedPath: "/Users/analyst/Records/mit-bih",
                bookmarkData: Data(),
                addedAt: Date(timeIntervalSinceNow: -3_600)
            ),
            RecentFolder(
                id: UUID(),
                displayName: "incartdb",
                resolvedPath: "/Users/analyst/Records/incartdb",
                bookmarkData: Data(),
                addedAt: Date(timeIntervalSinceNow: -86_400)
            )
        ],
        onPickRecent: { _ in },
        onRemoveRecent: { _ in }
    )
    .frame(width: 900, height: 700)
}
