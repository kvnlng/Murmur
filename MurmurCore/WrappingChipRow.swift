//
//  WrappingChipRow.swift
//  MurmurCore
//
//  A row of controls that wraps instead of insisting on one line (#223).
//
//  The interval trend lane's caption row ends in seven `.fixedSize()` control
//  chips — metric, formula, T-offset gate, CV flag, bin, show-mode, add-guide.
//  `.fixedSize()` is right for each one individually (a chip whose label
//  truncates is a control that doesn't say what it does), but seven of them in
//  an `HStack` compose into a 633 pt floor that nothing above can compress.
//  In a 1100 pt window the lane's cell is ~506 pt, so the last chips were
//  clipped away by the cell's own `.clipped()` — present in the layout,
//  invisible and unclickable.
//
//  Wrapping is the honest answer: a chip that doesn't fit on this line goes on
//  the next one, and the row's minimum becomes its WIDEST chip rather than the
//  sum of all of them. Nothing is hidden at any width a window can produce.
//
//  Trailing-aligned, because this is a right-hand control cluster: with the
//  row on one line the result is pixel-identical to the `HStack` it replaces.
//

import SwiftUI

/// Lays subviews out left-to-right, wrapping to a new line when the next one
/// would not fit, with each line pushed to the trailing edge.
///
/// Reports the width it actually uses — never the whole proposal — so it can
/// sit after a `Spacer` in an `HStack` and still hug the trailing edge.
struct WrappingChipRow: Layout {
    /// Gap between chips on a line.
    var spacing: CGFloat = 6
    /// Gap between wrapped lines.
    var lineSpacing: CGFloat = 4

    /// A subview and the size it asked for. A struct rather than a tuple:
    /// SwiftLint's `large_tuple` is a build error here, and a named pair reads
    /// better in the placement loop regardless.
    private struct Chip {
        let index: Int
        let size: CGSize
    }

    /// Chips grouped into the lines they land on at `width`.
    ///
    /// Each chip is measured `.unspecified` — they are `.fixedSize()` controls,
    /// so their ideal size IS their size, and asking them to fit a narrower
    /// proposal would just get the same answer more slowly.
    private func lines(_ subviews: Subviews, width: CGFloat) -> [[Chip]] {
        var lines: [[Chip]] = [[]]
        var used: CGFloat = 0
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let isFirstOnLine = lines[lines.count - 1].isEmpty
            let extent = isFirstOnLine ? size.width : used + spacing + size.width
            // A chip wider than the whole row still gets a line of its own
            // rather than an empty one above it — hence the first-on-line
            // exemption. It will overflow, but only by as much as one chip is
            // too wide, and only at a width no window produces.
            if !isFirstOnLine && extent > width {
                lines.append([Chip(index: index, size: size)])
                used = size.width
            } else {
                lines[lines.count - 1].append(Chip(index: index, size: size))
                used = extent
            }
        }
        return lines
    }

    private func lineWidth(_ line: [Chip]) -> CGFloat {
        guard !line.isEmpty else { return 0 }
        return line.reduce(0) { $0 + $1.size.width } + spacing * CGFloat(line.count - 1)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard !subviews.isEmpty else { return .zero }
        // An unspecified proposal asks for the ideal, which for a row of chips
        // is the one-line arrangement.
        let laid = lines(subviews, width: proposal.width ?? .infinity)
        let height = laid.reduce(0) { $0 + ($1.map(\.size.height).max() ?? 0) }
            + lineSpacing * CGFloat(max(0, laid.count - 1))
        return CGSize(width: laid.map(lineWidth).max() ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for line in lines(subviews, width: bounds.width) {
            var x = bounds.maxX - lineWidth(line)
            let lineHeight = line.map(\.size.height).max() ?? 0
            for chip in line {
                subviews[chip.index].place(
                    at: CGPoint(x: x, y: y + (lineHeight - chip.size.height) / 2),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(chip.size))
                x += chip.size.width + spacing
            }
            y += lineHeight + lineSpacing
        }
    }
}
