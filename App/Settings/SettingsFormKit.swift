// What the settings forms share on a phone, on Mac/Core's field model (SettingsLogic.swift): a field's label with its
// hint behind an info button, the boxes for text, lists and secrets, the guard that asks before unsaved changes go, and
// the lists the Settings tab reads (which the forms read too).
import Combine
import SwiftUI

// MARK: - The lists

@MainActor
final class SettingsLists: ObservableObject {
    static let shared = SettingsLists()

    /// One of the Settings tab's lists: the server's rows in their order, what a new one starts from, and how the last
    /// read went.
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
    /// The tokens issued, and (in `defaults`) the projects one can be held to.
    @Published var devices = Section()
    /// A reorder is on its way.
    @Published private(set) var ordering = false

    private var signOut: AnyCancellable?

    private init() {
        // Another connection sees other rows; what was read goes with the one that read it.
        signOut = Store.shared.$client.map { $0 != nil }.removeDuplicates().dropFirst().sink { connected in
            guard !connected else { return }
            MainActor.assumeIsolated { SettingsLists.shared.reset() }
        }
    }

    private func reset() {
        projects = Section(); providers = Section(); servers = Section(); ssh = Section(); devices = Section()
        ordering = false
    }

    private func load(_ section: ReferenceWritableKeyPath<SettingsLists, Section>, _ call: String, _ listKey: String,
                      defaultsKey: String = "defaults") async throws {
        guard Store.shared.supports(call) else { self[keyPath: section] = Section(loaded: true); return }
        do {
            let r = try await Store.shared.call(call)
            self[keyPath: section] = Section(list: r[listKey].items, defaults: r[defaultsKey], loaded: true, error: nil)
        } catch {
            guard let text = failure(error) else { throw error }
            self[keyPath: section].loaded = true
            self[keyPath: section].error = text
            throw error
        }
    }

    func loadProjects() async throws { try await load(\.projects, "settings_projects", "projects") }
    func loadProviders() async throws { try await load(\.providers, "settings_providers", "providers") }
    func loadServers() async throws { try await load(\.servers, "settings_db_servers", "servers") }
    func loadSSH() async throws { try await load(\.ssh, "settings_ssh_servers", "servers") }
    func loadDevices() async throws { try await load(\.devices, "settings_devices", "devices", defaultsKey: "projects") }

    /// Every list afresh; the first failure is what a poll backs off on.
    func refresh() async throws {
        var first: Error?
        for read in [loadProjects, loadProviders, loadServers, loadSSH, loadDevices] {
            do { try await read() } catch { if first == nil { first = error } }
        }
        if let first { throw first }
    }

    // MARK: Order

    /// Moves projects within the list, which is also the order the dashboard's sidebar and composer use.
    func moveProjects(from source: IndexSet, to destination: Int) {
        guard !ordering else { return }
        var rows = projects.list
        rows.move(fromOffsets: source, toOffset: destination)
        guard rows != projects.list else { return }
        let ids: [JSON] = rows.map { JSON($0["id"].int32 ?? 0) }
        projects.list = rows
        ordering = true
        Task {
            defer { ordering = false }
            do {
                let r = try await Store.shared.call("order_projects", ["ids": .array(ids)])
                if r["projects"].isArray {
                    projects.list = r["projects"].items
                    projects.error = nil
                }
                try? await ProjectsModel.shared.load()
            } catch {
                if let text = failure(error) { projects.error = text }
                try? await loadProjects()
            }
        }
    }

    /// The servers in the pool: one open session with a database per server.
    var poolCapacity: Int { DBServerFormState.poolCapacity(servers.list) }
}

/// Why the settings behind `call` cannot be shown with this token, or nil when they can.
@MainActor
func settingsUnavailableReason(_ call: String, path: String, what: String, manage: String) -> String? {
    let store = Store.shared
    return settingsUnavailableText(supported: store.supports(call), listed: store.routes.contains { $0.path.hasSuffix(path) },
                                   permission: store.device?.permission, what: what, path: path, manage: manage)
}

/// What a save answered without the row it should carry.
let settingsUnexpectedResponse = "The server returned an unexpected response."

// MARK: - Fields

/// A field's hint behind a tappable info button by its label; a tap shows it in a popover, on a phone too.
struct SettingsInfoButton: View {
    var label: String
    var text: String
    var rich = false
    @State private var shown = false
    var body: some View {
        Button { shown = true } label: {
            Image(systemName: "info.circle").font(.subheadline).foregroundStyle(.secondary)
                .frame(minWidth: 28, minHeight: 28).contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("About \(label)")
        .accessibilityHint(text)
        .popover(isPresented: $shown, arrowEdge: .top) {
            Group { if rich { Text(inlineMarkdown(text)) } else { Text(text) } }
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 320, alignment: .leading)
                .padding(16)
                .presentationCompactAdaptation(.popover)
        }
    }
}

/// A field's label, with its info button when it has a hint.
struct SettingsLabel: View {
    var label: String
    var hint: String?
    var rich = false
    var enabled = true
    var body: some View {
        HStack(spacing: 2) {
            Text(label).font(.subheadline.weight(.medium)).foregroundStyle(enabled ? .primary : .secondary)
            if let hint, !hint.isEmpty { SettingsInfoButton(label: label, text: hint, rich: rich) }
            Spacer(minLength: 0)
        }
        .frame(minHeight: 28)
    }
}

/// A labelled box for one of a form's fields: one line, many (a list or a long text, growing with its lines), or a
/// secret with a button that shows it.
struct SettingsTextRow<FocusKey: Hashable>: View {
    var def: SettingsField
    @Binding var text: String
    var enabled = true
    /// Shown in place of the definition's hint.
    var hint: String? = nil
    var rich = false
    var focus: FocusState<FocusKey?>.Binding
    var key: FocusKey
    var onSubmit: (() -> Void)? = nil
    @State private var revealed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            SettingsLabel(label: def.label, hint: hint ?? def.hint, rich: rich, enabled: enabled)
            box
                .font(def.mono ? .system(.callout, design: .monospaced) : .body)
                .foregroundStyle(enabled ? .primary : .secondary)
                .focused(focus, equals: key)
                .disabled(!enabled)
        }
        .padding(.vertical, 2)
    }

    /// Anything typed for a machine (paths, commands, keys) goes in as typed.
    private var literal: Bool { def.mono || def.secret || def.kind == .list || def.kind == .number }

    @ViewBuilder private var box: some View {
        if def.isMultiline {
            TextField(def.cue ?? "", text: $text, axis: .vertical)
                .lineLimit(max(def.rows, 2)...40)
                .textInputAutocapitalization(literal ? .never : .sentences)
                .autocorrectionDisabled(literal)
        } else if def.secret && !revealed {
            HStack {
                SecureField(def.cue ?? "", text: $text).textContentType(.none).onSubmit { onSubmit?() }
                revealButton
            }
        } else {
            HStack {
                TextField(def.cue ?? "", text: $text)
                    .keyboardType(def.kind == .number ? (def.key == "workerBudgetUsd" ? .decimalPad : .numberPad) : .default)
                    .textInputAutocapitalization(literal ? .never : .sentences)
                    .autocorrectionDisabled(literal)
                    .submitLabel(onSubmit != nil ? .go : .done)
                    .onSubmit { onSubmit?() }
                if def.secret { revealButton }
            }
        }
    }

    private var revealButton: some View {
        Button { revealed.toggle() } label: {
            Image(systemName: revealed ? "eye.slash" : "eye").foregroundStyle(.secondary).frame(minWidth: 28, minHeight: 28)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(revealed ? "Hide \(def.label)" : "Show \(def.label)")
    }
}

/// A two-column label and value, as the provider's status rows.
struct SettingsValueRow: View {
    var label: String
    var value: String
    var mono = false
    var body: some View {
        LabeledContent {
            Text(value).font(mono ? .system(.footnote, design: .monospaced) : .body).multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        } label: {
            Text(label)
        }
    }
}

/// A test's or a check's verdict under its button: green when the server answered, red otherwise.
struct SettingsVerdict: View {
    var text: String
    var ok: Bool
    var body: some View {
        Label(text, systemImage: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
            .font(.footnote).foregroundStyle(ok ? Theme.success : Theme.danger)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A tab's title with a dot when it holds unsaved changes, for the segmented pickers.
func settingsTabTitle(_ title: String, changed: Bool) -> String { changed ? "\(title) •" : title }

// MARK: - The form's frame

/// What a settings form's toolbar and guard need: whether it holds unsaved changes, what to say before they go, and its
/// actions.
struct SettingsFormChrome: ViewModifier {
    var title: String
    var dirty: Bool
    var discardMessage: String
    var saveTitle: String
    var canSave: Bool
    var saving: Bool
    var onSave: () -> Void
    /// Clone and Delete, for a saved row; nil hides each.
    var cloneTitle: String?
    var onClone: (() -> Void)?
    var deleteTitle: String?
    var onDelete: (() -> Void)?
    @Environment(\.dismiss) private var dismiss
    @State private var confirmLeave = false

    func body(content: Content) -> some View {
        content
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            // With changes not saved, going back asks first, and the edge swipe that would skip the question is off.
            .navigationBarBackButtonHidden(dirty)
            .toolbar {
                if dirty {
                    ToolbarItem(placement: .topBarLeading) {
                        Button { confirmLeave = true } label: {
                            HStack(spacing: 4) { Image(systemName: "chevron.backward").fontWeight(.semibold); Text("Back") }
                        }
                        .accessibilityLabel("Back")
                    }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if onClone != nil || onDelete != nil {
                        Menu {
                            if let onClone { Button(cloneTitle ?? "Clone", systemImage: "plus.square.on.square", action: onClone) }
                            if let onDelete { Button(deleteTitle ?? "Delete", systemImage: "trash", role: .destructive, action: onDelete) }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                        .accessibilityLabel("More")
                        .disabled(saving)
                    }
                    Button(action: onSave) {
                        if saving { ProgressView() } else { Text(saveTitle).fontWeight(.semibold) }
                    }
                    .disabled(!canSave)
                    .accessibilityLabel(saving ? "Saving" : saveTitle)
                }
            }
            .confirmationDialog("Discard unsaved changes?", isPresented: $confirmLeave, titleVisibility: .visible) {
                Button("Discard", role: .destructive) { dismiss() }
                Button("Keep editing", role: .cancel) {}
            } message: {
                Text(discardMessage)
            }
    }
}

/// Where a form scrolls to show its error.
let settingsErrorID = "settings-error"

/// A form's error, above its fields.
struct SettingsErrorSection: View {
    var error: String?
    var body: some View {
        if let error {
            Section { ErrorNotice(message: error).id(settingsErrorID) }.listRowBackground(Theme.danger.opacity(0.08))
        }
    }
}

/// The reason a form cannot be shown with this token, in place of the form.
struct SettingsUnavailableView: View {
    var text: String
    var body: some View {
        ContentUnavailableView {
            Label("Not available", systemImage: "lock")
        } description: {
            Text(text)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
    }
}
