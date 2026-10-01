// A pull request's changed files, page by page, pinned to one revision.
import Foundation

struct PullFile: Equatable, Sendable {
    var filename: String
    var previousFilename: String?
    var status: String?
    var patch: String?
    var url: String?
    /// Nil when the server sent none (the C client's -1); a negative count reads as none too.
    var additions: Int?
    var deletions: Int?

    init(filename: String) { self.filename = filename }
    /// Needs a string `filename`.
    init?(_ j: JSON) {
        guard let filename = j["filename"].string else { return nil }
        self.filename = filename
        previousFilename = j["previousFilename"].string
        status = j["status"].string
        patch = j["patch"].string
        url = j["url"].string
        additions = j["additions"].int32.flatMap { $0 >= 0 ? $0 : nil }
        deletions = j["deletions"].int32.flatMap { $0 >= 0 ? $0 : nil }
    }
    var json: JSON {
        ["filename": .string(filename), "previousFilename": .string(orNull: previousFilename), "status": .string(orNull: status),
         "additions": additions.map { JSON($0) } ?? .null, "deletions": deletions.map { JSON($0) } ?? .null,
         "patch": .string(orNull: patch), "url": .string(orNull: url)]
    }
    /// The last path component (the whole path when it ends in a slash).
    var name: String {
        guard let slash = filename.lastIndex(of: "/"), filename.index(after: slash) != filename.endIndex else { return filename }
        return String(filename[filename.index(after: slash)...])
    }
    /// The path without its last component; "" at the root.
    var directory: String {
        guard let slash = filename.lastIndex(of: "/") else { return "" }
        return String(filename[..<slash])
    }
}

private func parseFiles(_ list: JSON) -> [PullFile]? { list.array.map { $0.compactMap(PullFile.init) } }

/// One page of what `pull_files` answers.
struct PullFilesPage: Equatable, Sendable {
    var pr: JSON
    var files: [PullFile]
    /// Nil once there is no next page (the C client's 0).
    var nextPage: Int?
    var truncated: Bool

    init(pr: JSON = .null, files: [PullFile] = [], nextPage: Int? = nil, truncated: Bool = false) {
        self.pr = pr; self.files = files; self.nextPage = nextPage; self.truncated = truncated
    }
    /// Needs an object with a `files` array; files that do not read are skipped.
    init?(_ j: JSON) {
        guard j.isObject, let files = parseFiles(j["files"]) else { return nil }
        self.files = files
        pr = j["pr"]
        let next = j["nextPage"].int32 ?? 0
        nextPage = next == 0 ? nil : next
        truncated = j["truncated"].is(true)
    }
}

/// Pages of one pull request revision. Later pages are pinned to page 1's commits.
struct PullFileList: Equatable, Sendable {
    var pr: JSON = .null
    var files: [PullFile] = []
    /// Nil once every page was read; a new list starts on page 1.
    var nextPage: Int? = 1
    var truncated = false

    init() {}
    /// A saved list: an object with a `files` array.
    init?(_ j: JSON) {
        guard let page = PullFilesPage(j) else { return nil }
        pr = page.pr; files = page.files; nextPage = page.nextPage; truncated = page.truncated
    }
    var json: JSON {
        ["pr": pr, "files": .array(files.map(\.json)), "nextPage": nextPage.map { JSON($0) } ?? .null, "truncated": .bool(truncated)]
    }
    /// The arguments for the next page, or nil once every page was read. Without the revision to pin to, the shas are left
    /// out rather than sent empty.
    func arguments(repo: String, number: Int) -> JSON? {
        guard let next = nextPage else { return nil }
        var args: JSON = ["repo": .string(repo), "pr": JSON(number)]
        if next > 1 {
            args["page"] = JSON(next)
            if let head = pr["headSha"].string { args["headSha"] = .string(head) }
            if let base = pr["baseSha"].string { args["baseSha"] = .string(base) }
        }
        return args
    }
    /// Adds the page's files not already listed (by filename); the first page's details are the ones kept.
    mutating func append(_ page: PullFilesPage) {
        if files.isEmpty { pr = page.pr }
        var seen = Set(files.map(\.filename))
        for f in page.files where !seen.contains(f.filename) { seen.insert(f.filename); files.append(f) }
        nextPage = page.nextPage; truncated = page.truncated
    }
    /// A saved list of the revision this first page belongs to keeps its files and takes the page's details.
    mutating func confirm(_ page: PullFilesPage) -> Bool {
        guard let head = page.pr["headSha"].string, head == pr["headSha"].string, page.pr["baseSha"] == pr["baseSha"] else { return false }
        pr = page.pr
        return true
    }
}
