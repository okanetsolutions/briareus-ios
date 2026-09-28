import Foundation

/// Server responses kept on disk so a screen opens on what it last showed while the server is asked for changes.
/// Every failure is silent: a missing or unreadable entry only means the screen waits for the network.
public actor DiskCache {
    private let directory: URL
    private let files = FileManager.default
    public init(directory: URL) { self.directory = directory }

    public func value<T: Decodable & Sendable>(_ key: String, as type: T.Type = T.self) -> T? {
        guard let data = try? Data(contentsOf: url(key)) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
    @discardableResult
    public func store<T: Encodable & Sendable>(_ value: T, for key: String) -> Bool {
        // Sorted keys make equal values equal bytes, so an unchanged poll result costs no write.
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(value) else { return false }
        if (try? Data(contentsOf: url(key))) == data { return true }
        return write(data, to: key)
    }

    /// A log of values, one JSON document per line, that grows without being rewritten.
    public func lines<T: Decodable & Sendable>(_ key: String, as type: T.Type = T.self) -> [T] {
        guard let data = try? Data(contentsOf: url(key)) else { return [] }
        let decoder = JSONDecoder()
        return data.split(separator: 0x0A).compactMap { try? decoder.decode(T.self, from: Data($0)) }
    }
    @discardableResult
    public func append<T: Encodable & Sendable>(_ values: [T], to key: String) -> Bool {
        guard let data = Self.log(values) else { return false }
        guard files.fileExists(atPath: url(key).path) else { return write(data, to: key) }
        do {
            let handle = try FileHandle(forWritingTo: url(key))
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            return true
        } catch { return false }
    }
    @discardableResult
    public func replace<T: Encodable & Sendable>(_ values: [T], in key: String) -> Bool {
        guard let data = Self.log(values) else { return false }
        return write(data, to: key)
    }

    public func remove(_ key: String) { try? files.removeItem(at: url(key)) }
    public func removeAll() { try? files.removeItem(at: directory) }
    /// Drops entries nothing has written for a while, such as transcripts of conversations never reopened.
    public func prune(olderThan age: TimeInterval, now: Date = Date()) {
        let entries = (try? files.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for entry in entries {
            guard let modified = try? entry.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                  now.timeIntervalSince(modified) > age else { continue }
            try? files.removeItem(at: entry)
        }
    }

    private func url(_ key: String) -> URL {
        // Keys carry repository names and server ids; encoding leaves no path separators or dots.
        directory.appendingPathComponent(key.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "_")
    }
    private func write(_ data: Data, to key: String) -> Bool {
        do {
            var attributes: [FileAttributeKey: Any] = [:]
            var options: Data.WritingOptions = .atomic
            #if os(iOS)
            attributes[.protectionKey] = FileProtectionType.complete
            options.insert(.completeFileProtection)
            #endif
            try files.createDirectory(at: directory, withIntermediateDirectories: true, attributes: attributes)
            try data.write(to: url(key), options: options)
            return true
        } catch { return false }
    }
    private static func log<T: Encodable>(_ values: [T]) -> Data? {
        let encoder = JSONEncoder()
        var data = Data()
        for value in values {
            guard let line = try? encoder.encode(value) else { return nil }
            // The leading newline keeps a line cut short by an interrupted write from swallowing the next one.
            data.append(0x0A); data.append(line)
        }
        return data
    }
}
