// The files for a composer's next message or first prompt, as the Mac's Attachments (attach.c, attach_list.c): photos
// from the library or files from the Files app, each read off the main thread, uploaded at once, and shown as a chip with
// ✕ above the text until it is sent.
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class ComposerFiles: ObservableObject {
    /// A file for the next message: uploading until `fileID` is set.
    struct Item: Identifiable {
        let id = UUID()
        var name: String
        var size: Int
        var fileID: String?
    }

    @Published private(set) var items: [Item] = []
    /// Why files could not be attached, for an alert.
    @Published var notice: String?
    /// What the files go with: `message` or `start_session`.
    let call: String
    private var uploads: [UUID: Task<Void, Never>] = [:]

    init(call: String) { self.call = call }

    /// Whether the server takes files with `call` from this token.
    var supported: Bool { Store.shared.supportsAttachments(on: call) }
    var count: Int { items.count }
    var full: Bool { items.count >= attachmentsMax }
    var uploading: Bool { items.contains { $0.fileID == nil } }
    /// The uploaded files' ids, as the call's `attachments`; nil when there are none.
    var ids: JSON? {
        guard !items.isEmpty else { return nil }
        return .array(items.compactMap { $0.fileID.map(JSON.string) })
    }

    // MARK: Taking files

    /// Files picked in the Files app: security-scoped, so each is opened for the read.
    func take(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        Task {
            let result = await Task.detached(priority: .userInitiated) { ComposerFiles.readFiles(urls) }.value
            arrived(result.files, error: result.error)
        }
    }
    /// Photos and videos from the library. A photo goes as JPEG unless it already is a PNG, JPEG or GIF: the agent reads
    /// those, and not every one reads HEIC.
    func take(_ picked: [PhotosPickerItem]) {
        guard !picked.isEmpty else { return }
        Task {
            var files: [(String, Data)] = [], errors: [String] = []
            let stamp = ComposerFiles.stamp()
            for (n, item) in picked.enumerated() {
                let type = item.supportedContentTypes.first
                let base = picked.count == 1 ? stamp : "\(stamp)-\(n + 1)"
                guard let data = try? await item.loadTransferable(type: Data.self), !data.isEmpty else {
                    errors.append(attachmentRefusal("A photo", "could not be read")); continue
                }
                let encoded = await Task.detached(priority: .userInitiated) { ComposerFiles.encode(data, type: type, base: base) }.value
                guard let encoded else { errors.append(attachmentRefusal("A photo", "could not be encoded")); continue }
                if encoded.1.count > APIClient.uploadLimit { errors.append(attachmentRefusal(encoded.0, "is larger than 25 MB, the most a message takes")); continue }
                files.append(encoded)
            }
            arrived(files, error: errors.isEmpty ? nil : errors.joined(separator: "\n"))
        }
    }

    nonisolated private static func stamp() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMddHHmmss"
        return f.string(from: Date())
    }
    nonisolated private static func encode(_ data: Data, type: UTType?, base: String) -> (String, Data)? {
        guard let type, type.conforms(to: .image) else {
            return ("media-\(base).\(type?.preferredFilenameExtension ?? "bin")", data)
        }
        if type.conforms(to: .png) { return ("photo-\(base).png", data) }
        if type.conforms(to: .jpeg) { return ("photo-\(base).jpg", data) }
        if type.conforms(to: .gif) { return ("photo-\(base).gif", data) }
        guard let jpeg = UIImage(data: data)?.jpegData(compressionQuality: 0.85) else { return nil }
        return ("photo-\(base).jpg", jpeg)
    }

    nonisolated private static func readFiles(_ urls: [URL]) -> (files: [(String, Data)], error: String?) {
        var files: [(String, Data)] = [], errors: [String] = []
        for url in urls {
            let name = url.lastPathComponent
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            var directory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &directory) else { errors.append(attachmentRefusal(name, "could not be read")); continue }
            if directory.boolValue { errors.append(attachmentRefusal(name, "is a folder; attach its files")); continue }
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? nil
            if size == 0 { errors.append(attachmentRefusal(name, "is empty")); continue }
            if let size, size > APIClient.uploadLimit { errors.append(attachmentRefusal(name, "is larger than 25 MB, the most a message takes")); continue }
            guard let data = try? Data(contentsOf: url) else { errors.append(attachmentRefusal(name, "could not be read")); continue }
            if data.isEmpty { errors.append(attachmentRefusal(name, "is empty")); continue }
            if data.count > APIClient.uploadLimit { errors.append(attachmentRefusal(name, "is larger than 25 MB, the most a message takes")); continue }
            files.append((name, data))
        }
        return (files, errors.isEmpty ? nil : errors.joined(separator: "\n"))
    }

    // MARK: Uploading

    /// The files read: each goes to the server at once, and the call carries their ids.
    private func arrived(_ files: [(String, Data)], error: String?) {
        var refused: [String] = error.map { [$0] } ?? []
        for (name, bytes) in files {
            if items.count >= attachmentsMax { refused.append("At most \(attachmentsMax) files go with one message."); break }
            let item = Item(name: name, size: bytes.count)
            items.append(item)
            let id = item.id
            uploads[id] = Task {
                do {
                    let fileID = try await Store.shared.upload(name: name, bytes: bytes)
                    guard let i = items.firstIndex(where: { $0.id == id }) else { return }
                    items[i].fileID = fileID
                } catch {
                    guard !error.isCancellation, items.contains(where: { $0.id == id }) else { return }
                    remove(id)
                    notice = "\(name) could not be attached: \(errorText(error))"
                }
                uploads[id] = nil
            }
        }
        if !refused.isEmpty { notice = refused.joined(separator: "\n") }
    }

    /// Takes a file off the message, cancelling its upload.
    func remove(_ id: UUID) {
        uploads[id]?.cancel(); uploads[id] = nil
        items.removeAll { $0.id == id }
    }
    /// Drops the files whose ids went with a call that succeeded; one attached since stays.
    func sent(_ ids: JSON?) {
        let sent = Set((ids ?? .null).items.compactMap(\.string))
        for item in items where item.fileID.map(sent.contains) == true { remove(item.id) }
    }
    /// Cancels the uploads under way and forgets the files.
    func clear() { for item in items { remove(item.id) } }
}

// MARK: - Views

/// The chips above the composer's text: the name and size (… while uploading), ✕ to take it off.
struct AttachmentChipRow: View {
    @ObservedObject var files: ComposerFiles
    var enabled = true
    var body: some View {
        if !files.items.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(files.items) { item in
                        HStack(spacing: 4) {
                            if item.fileID == nil { ProgressView().controlSize(.mini) }
                            else { Image(systemName: "paperclip").font(.caption2).foregroundStyle(.secondary) }
                            Text(item.name).font(.caption).lineLimit(1).truncationMode(.middle).frame(maxWidth: 160, alignment: .leading)
                            Text(formatFileSize(item.size)).font(.caption2).foregroundStyle(.secondary)
                            Button { files.remove(item.id) } label: {
                                Image(systemName: "xmark.circle.fill").font(.footnote).foregroundStyle(.secondary)
                                    .frame(width: 24, height: 24).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain).disabled(!enabled)
                            .accessibilityLabel("Remove \(item.name)")
                        }
                        .padding(.leading, 9).padding(.trailing, 2).padding(.vertical, 2)
                        .background(Theme.surface, in: Capsule())
                        .overlay(Capsule().stroke(Theme.border, lineWidth: 0.5))
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
    }
}

/// The 📎 button: a menu of the photo library and the Files app, each opening its own picker.
struct AttachMenu: View {
    @ObservedObject var files: ComposerFiles
    var enabled = true
    @State private var choosingPhotos = false
    @State private var choosingFiles = false
    @State private var photos: [PhotosPickerItem] = []

    var body: some View {
        Menu {
            Button("Photo Library", systemImage: "photo.on.rectangle") { choosingPhotos = true }
            Button("Files", systemImage: "folder") { choosingFiles = true }
        } label: {
            Image(systemName: "paperclip").font(.footnote.weight(.semibold)).foregroundStyle(.primary)
                .frame(width: 32, height: 32).background(Theme.bubble, in: Circle())
        }
        .disabled(!enabled || files.full)
        .accessibilityLabel("Attach files")
        .photosPicker(isPresented: $choosingPhotos, selection: $photos, maxSelectionCount: max(1, attachmentsMax - files.count),
                      matching: .any(of: [.images, .screenshots, .videos]))
        .onChange(of: photos) { _, picked in
            guard !picked.isEmpty else { return }
            files.take(picked)
            photos = []
        }
        .fileImporter(isPresented: $choosingFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): files.take(urls)
            case .failure(let error): files.notice = "The files could not be opened: \(error.localizedDescription)"
            }
        }
        .alert("Attachments", isPresented: Binding(get: { files.notice != nil }, set: { if !$0 { files.notice = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(files.notice ?? "") }
    }
}
