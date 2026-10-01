// The sidebar's foot (screen_projects.c sidebar_footer_paint, player_paint and the sessions screen's bulk bar): while ☑
// Select is on, the count, Select all, ⏻ Close, 🗑 Delete and 🗑 Delete all; the player while something plays, with ⏮ ⏯ ⏭;
// and `☑ Select`, the version and `⎋` above a border.
import SwiftUI

/// A hairline across the sidebar, 10px in from each side.
private struct FootRule: View {
    var body: some View { Rectangle().fill(Theme.line).frame(height: 1).padding(.horizontal, 10) }
}

/// Text that reacts to clicks within 4px of itself, as the foot's hit rectangles are inflated.
private struct FootText: View {
    var text: String
    var font: Font
    var color: Color
    var action: (() -> Void)?
    var body: some View {
        let label = Text(text).font(font).foregroundStyle(color).lineLimit(1).frame(height: 18)
        if let action {
            Button(action: action) { label.padding(4).contentShape(Rectangle()) }.buttonStyle(.plain).padding(-4)
        } else { label }
    }
}

struct SidebarFooter: View {
    /// The sessions screen's ☑ Select state and its bar; nil on the projects screen, where ☑ Select does nothing.
    var sessions: SidebarSessions?
    var signOut: () -> Void
    @ObservedObject private var media = Media.shared

    var body: some View {
        VStack(spacing: 0) {
            if let sessions { BulkBar(model: sessions) }
            if media.state.available { player }
            foot
        }
        .background(Theme.sidebar)
    }

    // MARK: Player

    private var player: some View {
        let st = media.state
        let title = !st.title.isEmpty ? st.title : st.spotify ? "Spotify" : "Nothing playing"
        return VStack(spacing: 0) {
            Color.clear.frame(height: 6)
            FootRule()
            Color.clear.frame(height: 8)
            HStack(spacing: 0) {
                // Spotify's green on its own player, the muted note on another's.
                Image(systemName: Glyph.symbol(0xE8D6)).font(.system(size: 14))
                    .foregroundStyle(st.spotify ? Color(.sRGB, red: 0x1D / 255.0, green: 0xB9 / 255.0, blue: 0x54 / 255.0) : Theme.muted)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 0) {
                    Text(title).font(Theme.captionSemibold).foregroundStyle(Theme.ink).lineLimit(1).truncationMode(.tail).frame(height: 18)
                    if !st.artist.isEmpty {
                        Text(st.artist).font(Theme.caption2).foregroundStyle(Theme.muted).lineLimit(1).truncationMode(.tail).frame(height: 16)
                    } else { Color.clear.frame(height: 16) }
                }
                .padding(.leading, 8).padding(.trailing, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                playerButton(Glyph.symbol(0xE892), size: 12, ring: false, tip: "Previous") { media.send(.previous) }
                playerButton(Glyph.symbol(st.playing ? 0xE769 : 0xE768), size: 14, ring: true, tip: st.playing ? "Pause" : "Play") { media.send(.toggle) }
                playerButton(Glyph.symbol(0xE893), size: 12, ring: false, tip: "Next") { media.send(.next) }
            }
            .frame(height: 36)
            .padding(.leading, 16).padding(.trailing, 10)
            Color.clear.frame(height: 2)
        }
    }

    private func playerButton(_ symbol: String, size: CGFloat, ring: Bool, tip: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: size)).foregroundStyle(Theme.ink)
                .frame(width: 26, height: 26)
                .background { if ring { Circle().fill(Theme.raise).overlay(Circle().strokeBorder(Theme.line, lineWidth: 1)) } }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(tip)
    }

    // MARK: Foot

    private var version: String { "v" + (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "") }

    private var foot: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: 6)
            FootRule()
            Color.clear.frame(height: 10)
            ZStack {
                Text(version).font(Theme.caption2).foregroundStyle(Theme.tertiary).frame(height: 18)
                HStack(spacing: 0) {
                    SelectToggle(sessions: sessions)
                    Spacer(minLength: 8)
                    FootText(text: "⎋", font: Theme.footnote, color: Theme.muted, action: signOut).help("Sign out")
                }
            }
            .padding(.horizontal, 16)
            Color.clear.frame(height: 12)
        }
    }
}

/// `☑ Select`: ink while on. It turns ☑ Select on and off inside a project; on the projects list it is drawn but does nothing.
private struct SelectToggle: View {
    var sessions: SidebarSessions?
    var body: some View {
        if let sessions { Observed(model: sessions) } else { FootText(text: "☑ Select", font: Theme.footnote, color: Theme.muted, action: nil) }
    }
    private struct Observed: View {
        @ObservedObject var model: SidebarSessions
        var body: some View {
            FootText(text: "☑ Select", font: Theme.footnote, color: model.selectMode ? Theme.ink : Theme.muted) { model.toggleSelectMode() }
        }
    }
}

/// The bulk bar above the foot while ☑ Select is on: the count, Select all, ⏻ Close and 🗑 Delete, 🗑 Delete all.
private struct BulkBar: View {
    @ObservedObject var model: SidebarSessions
    private var dim: Color { Theme.muted.opacity(0.5) }

    var body: some View {
        if model.selectMode {
            let can = !model.picked.isEmpty && !model.bulkRunning
            VStack(spacing: 0) {
                Color.clear.frame(height: 6)
                FootRule()
                Color.clear.frame(height: 10)
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        Text("\(model.picked.count) selected").font(Theme.footnote).foregroundStyle(Theme.muted).lineLimit(1).truncationMode(.tail)
                            .frame(height: 18)
                        Spacer(minLength: 8)
                        FootText(text: "Select all", font: Theme.footnote, color: model.sessions.isEmpty ? dim : Theme.muted) { model.selectAll() }
                    }
                    Color.clear.frame(height: 6)
                    HStack(spacing: 6) {
                        bulkButton(model.bulkRunning && !model.bulkDelete ? "Closing…" : "⏻ Close", enabled: can) { model.bulk(delete: false, all: false) }
                        bulkButton(model.bulkRunning && model.bulkDelete ? "Deleting…" : "🗑 Delete", enabled: can) { model.bulk(delete: true, all: false) }
                    }
                    Color.clear.frame(height: 6)
                    HStack {
                        Button { model.bulk(delete: true, all: true) } label: {
                            Text("🗑 Delete all").font(Theme.caption).foregroundStyle(!model.sessions.isEmpty && !model.bulkRunning ? Theme.muted : dim)
                                .frame(height: 18).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Spacer(minLength: 0)
                    }
                    ZStack(alignment: .top) {
                        Color.clear.frame(height: 10)
                        if let error = model.bulkError {
                            Text(error).font(Theme.caption2).foregroundStyle(Theme.danger).lineLimit(1).truncationMode(.tail)
                                .frame(maxWidth: .infinity, alignment: .leading).frame(height: 14).offset(y: -8).help(error)
                        }
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }

    private func bulkButton(_ title: String, enabled: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(Theme.caption).foregroundStyle(enabled ? Theme.ink : Theme.muted)
                .frame(maxWidth: .infinity).frame(height: 30)
                .background(RoundedRectangle(cornerRadius: 7).fill(Theme.raise))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.line, lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
