// What the settings page's sidebar and its forms share, as screen_settings.c keeps it: the lists the sidebar read (the
// projects, providers, database pool and SSH servers, which the forms also read), the menus the pickers pop up, and the
// form's pieces: labelled boxes, check rows, select boxes, notes and the tab row.
import AppKit
import Combine
import SwiftUI

// MARK: - The lists

@MainActor
final class SettingsModel: ObservableObject {
    static let shared = SettingsModel()

    /// One of the sidebar's lists: the server's rows in their order, what a new one starts from, and how the last read went.
    struct Section: Equatable {
        var list: [JSON] = []
        var defaults: JSON = .null
        var loaded = false
        var error: String?
    }

    @Published var projects = Section()
    @Published var providers = Section()
    @Published var servers = Section()
    @Published var ssh = Section()
    /// A Move up or Move down is on its way.
    @Published private(set) var ordering = false

    private var tasks: [String: Task<Void, Never>] = [:]
    private var modeWatch: AnyCancellable?
    /// Open the first row once the list is read (after a delete).
    private var openFirstProvider = false, openFirstServer = false

    private init() {
        let center = NotificationCenter.default
        center.addObserver(forName: .settingsProjectsChanged, object: nil, queue: .main) { _ in
            Task { @MainActor in SettingsModel.shared.loadProjects() }
        }
        center.addObserver(forName: .settingsProvidersChanged, object: nil, queue: .main) { note in
            let first = note.userInfo?["openFirst"] as? Bool ?? false
            Task { @MainActor in SettingsModel.shared.openFirstProvider = first; SettingsModel.shared.loadProviders() }
        }
        center.addObserver(forName: .settingsDBServersChanged, object: nil, queue: .main) { note in
            let first = note.userInfo?["openFirst"] as? Bool ?? false
            Task { @MainActor in SettingsModel.shared.openFirstServer = first; SettingsModel.shared.loadServers() }
        }
        center.addObserver(forName: .sshServersChanged, object: nil, queue: .main) { _ in
            Task { @MainActor in SettingsModel.shared.loadSSH() }
        }
        // Each time the sidebar turns into the settings page, it reads everything afresh, as a new settings screen does.
        modeWatch = Navigator.shared.$sidebarMode.removeDuplicates().sink { mode in
            guard mode == .settings else { return }
            Task { @MainActor in SettingsModel.shared.start() }
        }
    }

    /// The settings page opening: everything is read afresh, as a new settings screen does.
    func start() {
        tasks.values.forEach { $0.cancel() }
        tasks = [:]
        projects = Section(); providers = Section(); servers = Section(); ssh = Section()
        ordering = false
        openFirstProvider = false; openFirstServer = false
        refresh()
    }
    func refresh() { loadProjects(); loadSSH(); loadProviders(); loadServers() }

    private func load(_ section: ReferenceWritableKeyPath<SettingsModel, Section>, _ call: String, _ listKey: String, done: @escaping () -> Void = {}) {
        tasks[call]?.cancel()
        guard Store.shared.supports(call) else { self[keyPath: section].loaded = true; return }
        tasks[call] = Task { [weak self] in
            do {
                let r = try await Store.shared.call(call)
                guard let self, !Task.isCancelled else { return }
                self[keyPath: section] = Section(list: r[listKey].items, defaults: r["defaults"], loaded: true, error: nil)
                done()
            } catch {
                guard let self, !error.isCancellation else { return }
                self[keyPath: section].loaded = true
                self[keyPath: section].error = errorText(error)
            }
        }
    }

    func loadProjects() {
        load(\.projects, "settings_projects", "projects") { [weak self] in
            // The dashboard's settings page opens on its first project, or on a new one when there is none; so does this,
            // unless a settings form is already up.
            guard let self, Navigator.shared.sidebarMode == .settings, !Self.isSettingsScreen(Navigator.shared.root) else { return }
            if self.projects.list.isEmpty { self.newProject() } else { self.openProject(0) }
        }
    }
    func loadSSH() { load(\.ssh, "settings_ssh_servers", "servers") }
    func loadProviders() {
        load(\.providers, "settings_providers", "providers") { [weak self] in
            // After a delete the first provider left opens in its place, as a project's delete opens the first project left.
            guard let self, self.openFirstProvider else { return }
            self.openFirstProvider = false
            guard !Self.isSettingsScreen(Navigator.shared.root) else { return }
            if self.providers.list.isEmpty { self.newProvider() } else { self.openProvider(0) }
        }
    }
    func loadServers() {
        load(\.servers, "settings_db_servers", "servers") { [weak self] in
            guard let self, self.openFirstServer else { return }
            self.openFirstServer = false
            guard !Self.isSettingsScreen(Navigator.shared.root) else { return }
            if self.servers.list.isEmpty { self.newServer() } else { self.openServer(0) }
        }
    }

    /// A settings form (or Devices and clients) in the detail pane.
    static func isSettingsScreen(_ screen: Screen) -> Bool {
        switch screen {
        case .projectSettings, .providerSettings, .dbServerSettings, .sshServerSettings, .devices: return true
        default: return false
        }
    }

    // MARK: Opening rows

    func openProject(_ i: Int) {
        guard projects.list.indices.contains(i), projects.list[i].isObject else { return }
        Navigator.shared.show(.projectSettings(row: projects.list[i], defaults: projects.defaults))
    }
    func newProject() { Navigator.shared.show(.projectSettings(row: nil, defaults: projects.defaults)) }
    func openProvider(_ i: Int) {
        guard providers.list.indices.contains(i), providers.list[i].isObject else { return }
        Navigator.shared.show(.providerSettings(row: providers.list[i], defaults: providers.defaults))
    }
    func newProvider() { Navigator.shared.show(.providerSettings(row: nil, defaults: providers.defaults)) }
    func openServer(_ i: Int) {
        guard servers.list.indices.contains(i), servers.list[i].isObject else { return }
        Navigator.shared.show(.dbServerSettings(row: servers.list[i], defaults: servers.defaults))
    }
    func newServer() { Navigator.shared.show(.dbServerSettings(row: nil, defaults: servers.defaults)) }
    func openSSH(_ i: Int) {
        guard ssh.list.indices.contains(i), ssh.list[i].isObject else { return }
        Navigator.shared.show(.sshServerSettings(row: ssh.list[i], defaults: ssh.defaults))
    }
    func newSSH() { Navigator.shared.show(.sshServerSettings(row: nil, defaults: ssh.defaults)) }

    // MARK: Order

    /// Moves a project up or down the list, which is also the order the dashboard's sidebar and composer use.
    func move(_ index: Int, by delta: Int) {
        let rows = projects.list, n = rows.count
        guard !ordering, index < n, !(delta < 0 && index == 0), !(delta > 0 && index + 1 >= n) else { return }
        let other = delta < 0 ? index - 1 : index + 1
        let ids: [JSON] = (0..<n).map { i in
            let from = i == index ? other : i == other ? index : i
            return JSON(rows[from]["id"].int32 ?? 0)
        }
        ordering = true
        Task {
            defer { ordering = false }
            do {
                let r = try await Store.shared.call("order_projects", ["ids": .array(ids)])
                if r["projects"].isArray {
                    projects.list = r["projects"].items
                    projects.error = nil
                    post(.projectsChanged)
                }
            } catch {
                if !error.isCancellation { projects.error = errorText(error) }
            }
        }
    }

    /// The servers in the pool: one open session with a database per server.
    var poolCapacity: Int { DBServerFormState.poolCapacity(servers.list) }
}

/// Why the settings behind `call` cannot be shown with this token, or nil when they can.
@MainActor
func settingsUnavailable(_ call: String, path: String, what: String, manage: String) -> String? {
    let store = Store.shared
    return settingsUnavailableText(supported: store.supports(call), listed: store.routes.contains { $0.path.hasSuffix(path) },
                                   permission: store.device?.permission, what: what, path: path, manage: manage)
}

// MARK: - Menus

/// A menu under the pointer that answers which item was chosen, as the Windows client's TrackPopupMenu(TPM_RETURNCMD).
@MainActor
enum PopupMenu {
    struct Item {
        var title: String
        var checked = false
        var enabled = true
        var separator = false
        static let separatorItem = Item(title: "", separator: true)
    }
    private final class Target: NSObject {
        var chosen: Int?
        @objc func pick(_ sender: NSMenuItem) { chosen = sender.tag }
    }
    static func choose(_ items: [Item]) -> Int? {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let target = Target()
        for (i, item) in items.enumerated() {
            if item.separator { menu.addItem(.separator()); continue }
            let mi = NSMenuItem(title: item.title, action: #selector(Target.pick(_:)), keyEquivalent: "")
            mi.target = target
            mi.tag = i
            mi.state = item.checked ? .on : .off
            mi.isEnabled = item.enabled
            menu.addItem(mi)
        }
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        return target.chosen
    }
}

// MARK: - Form pieces

enum SettingsFonts {
    static func lineHeight(mono: Bool) -> CGFloat {
        let font = mono ? NSFont.monospacedSystemFont(ofSize: 13, weight: .regular) : NSFont.systemFont(ofSize: 15)
        return NSLayoutManager().defaultLineHeight(for: font)
    }
    static func font(mono: Bool) -> Font { mono ? Theme.mono : Theme.body }
    /// A 13px label's line, which the boxes sit under.
    static let footnoteLineHeight = NSLayoutManager().defaultLineHeight(for: NSFont.systemFont(ofSize: 13))
}

/// A box's frame: raise fill, 6px corners, the border in the accent while focused, faded when the box is off.
private struct BoxFrame: ViewModifier {
    var focused: Bool
    var enabled = true
    func body(content: Content) -> some View {
        let border = focused ? Theme.accentDim : Theme.line
        return content
            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.raise))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(enabled ? border : border.opacity(0.5), lineWidth: 1))
    }
}

/// A hint under a box: 12px muted, wrapped; `rich` reads `code` spans, as the provider form's hints have them.
struct SettingsHint: View {
    var text: String
    var rich = false
    var body: some View {
        Group {
            if rich, let a = try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
                Text(a)
            } else { Text(text) }
        }
        .font(Theme.caption).foregroundStyle(Theme.muted)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A note between the fields, with the space after it.
struct SettingsNote: View {
    var text: String
    var rich = false
    var after: CGFloat = 10
    var body: some View { SettingsHint(text: text, rich: rich).padding(.bottom, after) }
}

/// A labelled box with its text, and the hint under it, then 14px before the next; as the forms' `field()`.
struct SettingsFieldBox<FocusKey: Hashable>: View {
    var def: SettingsField
    @Binding var text: String
    var enabled = true
    /// Shown in place of the definition's hint.
    var hint: String? = nil
    var rich = false
    var focus: FocusState<FocusKey?>.Binding
    var key: FocusKey
    var onSubmit: () -> Void = {}

    private var shownHint: String? { hint ?? def.hint }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(def.label).font(Theme.footnote).foregroundStyle(enabled ? Theme.ink : Theme.muted).lineLimit(1)
                .padding(.bottom, 6)
            box
            if let shownHint { SettingsHint(text: shownHint, rich: rich).padding(.top, 6) }
        }
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var box: some View {
        let focused = focus.wrappedValue == key
        if def.isMultiline {
            // A long box grows with its lines, up to 40, and scrolls inside past them, as the dashboard's textareas do.
            let rows = min(max(SettingsText.lineCount(text), def.rows), 40)
            TextEditor(text: $text)
                .font(SettingsFonts.font(mono: def.mono))
                .scrollContentBackground(.hidden)
                .focused(focus, equals: key)
                .disabled(!enabled)
                .padding(.horizontal, 5).padding(.vertical, 8)
                .frame(height: CGFloat(rows) * SettingsFonts.lineHeight(mono: def.mono) + 16)
                .modifier(BoxFrame(focused: focused, enabled: enabled))
        } else {
            Group {
                if def.secret {
                    SecureField(def.cue ?? "", text: $text)
                } else {
                    TextField(def.cue ?? "", text: $text)
                }
            }
            .textFieldStyle(.plain)
            .font(SettingsFonts.font(mono: def.mono))
            .foregroundStyle(enabled ? Theme.ink : Theme.muted)
            .focused(focus, equals: key)
            .disabled(!enabled)
            .onSubmit(onSubmit)
            .padding(.horizontal, 10)
            .frame(height: 36)
            // A click on the box around the text focuses it too.
            .background(Color.clear.contentShape(Rectangle()).onTapGesture { if enabled { focus.wrappedValue = key } })
            .modifier(BoxFrame(focused: focused, enabled: enabled))
        }
    }
}

/// A check box and its label on a 26px row (36px beside boxes), as the forms' paint_check.
struct SettingsCheck: View {
    var label: String
    var on: Bool
    var height: CGFloat = 26
    var action: () -> Void
    @State private var hovered = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 3).fill(on ? Theme.accent : Theme.field)
                    RoundedRectangle(cornerRadius: 3).strokeBorder(on ? Theme.accent : hovered ? Theme.accentDim : Theme.lineStrong, lineWidth: 1)
                    if on { Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.onAccent) }
                }
                .frame(width: 15, height: 15)
                Text(label).font(Theme.footnote).foregroundStyle(Theme.ink).lineLimit(1).truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, minHeight: height, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}

/// A select box: its text and a chevron in a 36px box; a click pops its menu up.
struct SettingsSelect: View {
    var text: String
    var enabled = true
    var action: () -> Void
    @State private var hovered = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 0) {
                Text(text).font(Theme.footnote).foregroundStyle(enabled ? Theme.ink : Theme.muted).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 8)
                Image(systemName: Glyph.symbol(0xE70D)).font(.system(size: 10)).foregroundStyle(enabled ? Theme.ink : Theme.muted)
                    .frame(width: 16)
            }
            .padding(.leading, 12).padding(.trailing, 10)
            .frame(maxWidth: .infinity, minHeight: 36, maxHeight: 36)
            .background(RoundedRectangle(cornerRadius: 6).fill(enabled ? Theme.raise : Theme.raise.opacity(0.5)))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(hovered && enabled ? Theme.accentDim : Theme.line, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHover { hovered = $0 }
    }
}

/// A labelled select with its hint, then 14px; as select_box / ssh_select.
struct SettingsLabeledSelect: View {
    var label: String
    var text: String
    var enabled = true
    var hint: String? = nil
    var action: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(label).font(Theme.footnote).foregroundStyle(enabled ? Theme.ink : Theme.muted).lineLimit(1).padding(.bottom, 6)
            SettingsSelect(text: text, enabled: enabled, action: action)
            if let hint { SettingsHint(text: hint).padding(.top, 6) }
        }
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// GitHub's `tabnav` over a form, a dot after any tab with unsaved changes, 18px before the fields.
struct SettingsTabs: View {
    struct Tab: Identifiable {
        var id: Int
        var title: String
        var glyph: String
        var dot: Bool
    }
    var tabs: [Tab]
    var open: Int
    var select: (Int) -> Void
    var body: some View {
        TabNav {
            ForEach(tabs) { t in
                TabNavItem(glyph: t.glyph, title: t.title, active: t.id == open, dot: t.dot) { select(t.id) }
            }
        }
        .padding(.bottom, 18)
    }
}

/// A settings form's page: its header over the whole pane, scrolled, with the reason the form cannot be shown in place
/// of the form when there is one.
struct SettingsPage<Content: View>: View {
    var header: PaneHeader
    var unavailable: String?
    /// Changes whenever the page should scroll back to its top (an error was shown, a tab opened).
    var scrollToken: Int
    @ViewBuilder var content: Content
    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        Color.clear.frame(height: 8).id("top")
                        if let unavailable {
                            Text(unavailable).font(Theme.footnote).foregroundStyle(Theme.muted)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.top, 10).padding(.bottom, 12)
                        } else {
                            content
                            Color.clear.frame(height: 40)
                        }
                    }
                    .padding(.horizontal, Theme.paneMargin)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: scrollToken) { _, _ in proxy.scrollTo("top", anchor: .top) }
            }
        }
        .background(Theme.canvas)
    }
}

/// Two cells side by side, each half the width with 14px between, as the web's `.field-row`.
struct SettingsPair<A: View, B: View>: View {
    @ViewBuilder var left: A
    @ViewBuilder var right: B
    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            left.frame(maxWidth: .infinity, alignment: .topLeading)
            right.frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }
}

/// Asks before unsaved changes go, for a form's leave guard: "Discard unsaved changes?".
@MainActor
func confirmDiscard(_ message: String) -> Bool {
    Dialogs.confirm("Discard unsaved changes?", message, continueLabel: "Discard", destructive: true)
}

/// A form registers here whenever it holds unsaved changes, so another screen asks before replacing it.
@MainActor
func guardLeaving(_ canLeave: @escaping @MainActor () -> Bool) {
    Navigator.shared.leaveGuard = { canLeave() }
}

/// What a save answered without the row it should carry.
let unexpectedResponse = "The server returned an unexpected response."

/// A two-column label and value, as the provider's Status rows: 150px of muted label, then the value, wrapped.
struct SettingsStatusRow: View {
    var label: String
    var value: String
    var mono = false
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(label).font(Theme.footnote).foregroundStyle(Theme.muted).lineLimit(1).frame(width: 150, alignment: .leading)
            Text(value).font(mono ? Theme.mono : Theme.footnote).foregroundStyle(Theme.ink).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.bottom, 3)
    }
}
