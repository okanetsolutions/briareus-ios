import SwiftUI

/// A pull request's description and changed files, read a page at a time from one revision.
struct PullFilesView: View {
    let project: Project
    let number: Int
    @EnvironmentObject private var store: AppStore
    @State private var list = PullFileList()
    @State private var loading = false
    @State private var error: String?
    @State private var changed = false
    var body: some View {
        List {
            if changed {
                Label("This pull request changed while reading. Showing its latest revision.", systemImage: "arrow.triangle.2.circlepath")
                    .font(.footnote).foregroundStyle(.secondary).listRowBackground(Theme.elevated)
            }
            if list.pr != .null {
                Section("Description") {
                    let body = (list.pr["body"].string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    if body.isEmpty { Text("No description provided").foregroundStyle(.secondary) }
                    else { MarkdownText(body).font(.callout) }
                    if let author = list.pr["author"].string {
                        Label(author, systemImage: "person.crop.circle").font(.caption).foregroundStyle(.secondary)
                    }
                }.listRowBackground(Theme.elevated)
                Section {
                    ForEach(list.files) { file in
                        NavigationLink { FileDiffView(file: file) } label: { FileRow(file: file) }
                    }
                    if list.nextPage != nil && !list.files.isEmpty && error == nil {
                        ProgressView().frame(maxWidth: .infinity).task { await load() }
                    }
                    if list.files.isEmpty && list.nextPage == nil { Text("No files changed").foregroundStyle(.secondary) }
                } header: {
                    HStack(spacing: 8) {
                        Text(list.pr["changedFiles"].double.map { "\(Int($0)) files changed" } ?? "Files changed")
                        Spacer()
                        if let additions = list.pr["additions"].double, let deletions = list.pr["deletions"].double {
                            Text("+\(Int(additions))").foregroundStyle(Theme.success)
                            Text("−\(Int(deletions))").foregroundStyle(Theme.danger)
                        }
                    }.font(.caption.monospacedDigit()).textCase(nil)
                } footer: {
                    if list.truncated { Text("GitHub lists only the first 3,000 files of this pull request.") }
                }.listRowBackground(Theme.elevated)
            }
            if let error {
                Section {
                    ErrorNotice(message: error)
                    Button("Try again") { Task { await load() } }.disabled(loading)
                }.listRowBackground(Theme.elevated)
            }
            if list.pr == .null && error == nil {
                ProgressView("Loading changes…").frame(maxWidth: .infinity).padding(.vertical, 24).listRowBackground(Color.clear)
            }
        }
        .scrollContentBackground(.hidden).background(Theme.background)
        .navigationTitle("#\(number)").navigationBarTitleDisplayMode(.inline)
        .refreshable { list = PullFileList(); changed = false; await load() }
        .task { if list.pr == .null { await load() } }
    }
    private func load(retried: Bool = false) async {
        guard !loading, let args = list.arguments(repo: project.repo, number: number) else { return }
        loading = true; defer { loading = false }
        do {
            let page: PullFilesPage = try await store.call("pull_files", args)
            try Task.checkCancellation()
            list.append(page); error = nil
        } catch {
            if Task.isCancelled || error is CancellationError { return }
            // A push or rebase invalidates the pages already read; never mix two revisions.
            if case .http(409, _, _)? = error as? APIError, !retried {
                list = PullFileList(); changed = true; loading = false
                await load(retried: true)
            } else { self.error = error.localizedDescription }
        }
    }
}

private struct FileRow: View {
    let file: PullFile
    private var mark: (icon: String, color: Color) {
        switch file.status {
        case "added": return ("plus.square.fill", Theme.success)
        case "removed": return ("minus.square.fill", Theme.danger)
        case "renamed", "copied": return ("arrow.right.square.fill", Theme.accent)
        default: return ("square.and.pencil", Theme.warning)
        }
    }
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: mark.icon).font(.subheadline).foregroundStyle(mark.color)
            VStack(alignment: .leading, spacing: 3) {
                Text(file.name).font(.subheadline.monospaced().weight(.medium)).lineLimit(1).truncationMode(.middle)
                if !file.directory.isEmpty {
                    Text(file.directory).font(.caption2.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                }
                if let previous = file.previousFilename {
                    Text("from \(previous)").font(.caption2.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                }
            }
            Spacer(minLength: 6)
            HStack(spacing: 5) {
                Text("+\(file.additions ?? 0)").foregroundStyle(Theme.success)
                Text("−\(file.deletions ?? 0)").foregroundStyle(Theme.danger)
            }.font(.caption.monospacedDigit())
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(file.filename), \(file.status ?? "modified"), \(file.additions ?? 0) additions, \(file.deletions ?? 0) deletions")
    }
}

struct FileDiffView: View {
    let file: PullFile
    @State private var lines: [DiffLine] = []
    @State private var wrap = true
    var body: some View {
        ScrollView(wrap ? .vertical : [.vertical, .horizontal]) {
            LazyVStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(file.filename).font(.footnote.monospaced().weight(.medium)).textSelection(.enabled)
                    if let previous = file.previousFilename {
                        Text("Renamed from \(previous)").font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                }.padding(.horizontal, 12).padding(.vertical, 10)
                if file.patch == nil {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("No diff available", systemImage: "doc.questionmark").font(.subheadline.weight(.medium))
                        Text("GitHub returns no patch for binary files and very large changes.").font(.footnote).foregroundStyle(.secondary)
                    }.padding(12)
                }
                ForEach(lines) { line in DiffRow(line: line, wrap: wrap) }
                if let url = safeWebURL(file.url) {
                    Link(destination: url) { Label("Open file on GitHub", systemImage: "arrow.up.right") }
                        .font(.footnote).padding(12)
                }
            }
            .frame(maxWidth: wrap ? .infinity : nil, alignment: .leading)
        }
        .background(Theme.background)
        .navigationTitle(file.name).navigationBarTitleDisplayMode(.inline)
        .toolbar {
            Button { wrap.toggle() } label: { Image(systemName: wrap ? "arrow.left.and.right.text.vertical" : "text.word.spacing") }
                .accessibilityLabel(wrap ? "Scroll long lines" : "Wrap long lines")
        }
        .task { if lines.isEmpty, let patch = file.patch { lines = DiffLine.parse(patch) } }
    }
}

private struct DiffRow: View {
    let line: DiffLine
    let wrap: Bool
    private var tint: Color {
        switch line.kind {
        case .added: return Theme.success
        case .removed: return Theme.danger
        default: return .clear
        }
    }
    private var sign: String {
        switch line.kind {
        case .added: return "+"
        case .removed: return "−"
        default: return " "
        }
    }
    var body: some View {
        switch line.kind {
        case .hunk, .note:
            Text(line.text).font(.caption2.monospaced()).foregroundStyle(.secondary)
                .lineLimit(wrap ? nil : 1).fixedSize(horizontal: !wrap, vertical: false)
                .padding(.horizontal, 12).padding(.vertical, line.kind == .hunk ? 6 : 2)
                .frame(maxWidth: wrap ? .infinity : nil, alignment: .leading)
                .background(line.kind == .hunk ? Theme.surface : Color.clear)
        default:
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text((line.new ?? line.old).map(String.init) ?? "").font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary).frame(width: 34, alignment: .trailing)
                Text(sign).font(.caption.monospaced()).foregroundStyle(line.kind == .context ? Color.secondary : tint)
                Text(line.text.isEmpty ? " " : line.text).font(.caption.monospaced())
                    .lineLimit(wrap ? nil : 1).fixedSize(horizontal: !wrap, vertical: wrap)
                    .textSelection(.enabled)
            }
            .padding(.trailing, 12).padding(.vertical, 1.5)
            .frame(maxWidth: wrap ? .infinity : nil, alignment: .leading)
            .background(tint.opacity(0.13))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(line.kind == .added ? "Added" : line.kind == .removed ? "Removed" : "Line") \(line.text)")
        }
    }
}
