// The sidebar's rows (screen_projects.c): a project with its count, working dot and chevron, `‹ All projects`, and a
// conversation as the Windows client lists it, with its mark, title, and a wrapped line of provider, branch, state and age.
import AppKit
import SwiftUI

// MARK: - Project

/// paint_project_row: the name in 14px ink on the left; at the right the chevron, the count in 12px muted and the dot while
/// a conversation works. Raised when hovered or selected.
struct ProjectRow: View {
    var name: String
    var count: Int
    var busy = false
    var selected = false
    var chevron = true
    var height: CGFloat = 39
    var action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(name).font(Theme.subheadline).foregroundStyle(Theme.ink).lineLimit(1).truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if busy { StatusDot(status: "running") }
                Text(verbatim: "\(count)").font(Theme.caption).foregroundStyle(Theme.muted)
                if chevron { Text("›").font(Theme.caption2).foregroundStyle(Theme.muted).frame(width: 6, alignment: .trailing) }
            }
            .padding(.horizontal, 8)
            .frame(height: height)
            .background(RoundedRectangle(cornerRadius: 8).fill(hovered || selected ? Theme.raise : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}

/// paint_back_row: `‹ All projects`, muted, ink and raised on hover.
struct BackRow: View {
    var action: () -> Void
    @State private var hovered = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text("‹").font(Theme.footnote).frame(width: 8, alignment: .leading)
                Text("All projects").font(Theme.caption)
                Spacer(minLength: 0)
            }
            .foregroundStyle(hovered ? Theme.ink : Theme.muted)
            .padding(.leading, 8)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 8).fill(hovered ? Theme.raise : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}

// MARK: - Conversation

extension Session {
    /// The Windows client's `sessionState`: an idle conversation with a question up is "waiting".
    var sidebarState: String { status == "idle" && raw["awaitingAnswer"].is(true) ? "waiting" : status }
    /// How long ago it was created, "" without a date.
    var sidebarAge: String { boardDateParse(raw["createdAt"].string).map { formatRelative($0) } ?? "" }
    /// The branch chip: an orchestrator's ⚡ zeus or 🧭 orchestrator in place of the branch.
    var sidebarBranch: String {
        if raw["orchestrator"].is(true) || raw["zeus"].is(true) { return raw["zeus"].is(true) ? "⚡ zeus" : "🧭 orchestrator" }
        return raw["branch"].nonEmpty ?? ""
    }
    /// The pull request's state for its mark: open, draft, merged or closed; nil without one.
    var sidebarPRState: String? {
        let pr = raw["prStatus"]
        guard let state = pr["state"].string else { return nil }
        return state == "open" && pr["draft"].is(true) ? "draft" : state
    }
}

/// paint_session_row.
struct SidebarSessionRow: View {
    var session: Session
    var lit: Bool
    var selectMode: Bool
    var picked: Bool
    var action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 0) {
                if selectMode {
                    CheckBox(on: picked).padding(.top, 4).padding(.trailing, 8)
                }
                Color.clear.frame(width: 16, height: 1)   // the fold gutter and the gap after it
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 7) {
                        mark
                        Text(session.displayTitle).font(Theme.subheadline).foregroundStyle(Theme.ink).lineLimit(1).truncationMode(.tail)
                        Spacer(minLength: 0)
                    }
                    .frame(height: 23)
                    meta
                }
            }
            .padding(.leading, 8).padding(.trailing, 8).padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(hovered || lit ? Theme.raise : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }

    @ViewBuilder private var mark: some View {
        if let pr = session.sidebarPRState {
            PullRequestMark(color: pr == "open" ? Theme.ok : pr == "merged" ? Theme.accent : pr == "closed" ? Theme.danger : Theme.muted)
        } else {
            StatusDot(status: session.sidebarState)
        }
    }

    private var meta: some View {
        let chipFill = hovered || lit ? Theme.raise : Theme.sidebar
        let branch = session.sidebarBranch, age = session.sidebarAge
        return SessionMetaLayout {
            MetaChip(text: session.provider ?? "", fill: chipFill)
            if branch.isEmpty { Color.clear.frame(width: 0, height: 0) } else { MetaChip(text: branch, fill: chipFill) }
            metaText(session.sidebarState)
            metaText(age)
        }
    }
    @ViewBuilder private func metaText(_ text: String) -> some View {
        if text.isEmpty { Color.clear.frame(width: 0, height: 0) }
        else { Text(text).font(Theme.caption).foregroundStyle(Theme.muted).lineLimit(1).fixedSize() }
    }
}

/// The provider and branch chips: `rounded px-[5px] text-[11px]` on the row's colour, bordered.
private struct MetaChip: View {
    var text: String
    var fill: Color
    var body: some View {
        Text(text).font(Theme.caption2).foregroundStyle(Theme.muted).lineLimit(1).truncationMode(.tail)
            .padding(.leading, 5).padding(.trailing, 7)
            .frame(maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: 4).fill(fill))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.line, lineWidth: 1))
            .padding(.vertical, 1)
    }
}

/// meta_layout: provider chip, branch chip (at most 45% wide), state and age, `gap-2` apart on 20px lines, wrapping as
/// `flex-wrap` does. The state and its age wrap as one, so "waiting" never sits a line above "11h ago". A zero-width
/// subview is absent.
struct SessionMetaLayout: Layout {
    static let lineHeight: CGFloat = 20, gap: CGFloat = 8

    private func frames(_ width: CGFloat, _ subviews: Subviews) -> ([CGRect], CGFloat) {
        var widths = subviews.map { ceil($0.sizeThatFits(.unspecified).width) }
        if widths.count > 1 { widths[1] = min(widths[1], (width * 45 / 100).rounded(.down)) }
        var rects = Array(repeating: CGRect.zero, count: widths.count)
        var x: CGFloat = 0, y: CGFloat = 0
        for i in widths.indices {
            guard widths[i] > 0 else { continue }
            let need = widths[i] + (i == 2 && widths.count > 3 && widths[3] > 0 ? Self.gap + widths[3] : 0)
            let joined = i == 3 && rects[2] != .zero
            if x > 0 && !joined && x + need > width { x = 0; y += Self.lineHeight }
            rects[i] = CGRect(x: x, y: y, width: widths[i], height: Self.lineHeight)
            x += widths[i] + Self.gap
        }
        return (rects, y + Self.lineHeight)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 10_000
        return CGSize(width: width, height: frames(width, subviews).1)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rects = frames(bounds.width, subviews).0
        for (i, sub) in subviews.enumerated() {
            let r = rects[i]
            sub.place(at: CGPoint(x: bounds.minX + r.minX, y: bounds.minY + r.minY), proposal: ProposedViewSize(width: r.width, height: r.height))
        }
    }
}

/// draw_pr_mark: GitHub's pull request mark in 13px, a branch with a commit at each end and the merge ring beside it.
struct PullRequestMark: View {
    var color: Color
    var body: some View {
        Canvas { ctx, _ in
            let s: CGFloat = 13, w: CGFloat = 2
            let lx = s * 3 / 13, top = s * 3 / 13, bottom = s * 11 / 13, rx = s * 10 / 13
            var lines = Path()
            lines.move(to: CGPoint(x: lx, y: top)); lines.addLine(to: CGPoint(x: lx, y: bottom))
            lines.move(to: CGPoint(x: rx, y: bottom)); lines.addLine(to: CGPoint(x: rx, y: s * 5 / 13))
            lines.move(to: CGPoint(x: rx, y: s * 4 / 13)); lines.addLine(to: CGPoint(x: s * 6 / 13, y: s * 4 / 13))
            ctx.stroke(lines, with: .color(color), lineWidth: w)
            let r = s * 2 / 13 + 0.5
            for c in [CGPoint(x: lx, y: top), CGPoint(x: lx, y: bottom), CGPoint(x: rx, y: bottom)] {
                ctx.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)), with: .color(color))
            }
        }
        .frame(width: 13, height: 13)
    }
}

/// The 13px tick box of ☑ Select: the accent with a tick when picked, the field colour with a strong border otherwise.
struct CheckBox: View {
    var on: Bool
    var body: some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(on ? Theme.accent : Theme.field)
            .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(on ? Theme.accent : Theme.lineStrong, lineWidth: 1))
            .overlay {
                if on {
                    Canvas { ctx, size in
                        var p = Path()
                        p.move(to: CGPoint(x: size.width * 0.24, y: size.height * 0.52))
                        p.addLine(to: CGPoint(x: size.width * 0.42, y: size.height * 0.70))
                        p.addLine(to: CGPoint(x: size.width * 0.76, y: size.height * 0.32))
                        ctx.stroke(p, with: .color(Theme.onAccent), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                    }
                }
            }
            .frame(width: 13, height: 13)
    }
}
