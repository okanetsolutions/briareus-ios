// What Spotify (or, without it, Music) is playing, and its ⏮ ⏯ ⏭, for the foot of the sidebar. The Windows client reads
// Windows' media sessions; a Mac publishes none to other apps, so the players are asked over Apple Events instead. No
// Spotify account or Web API: only the desktop app running. Nothing is asked of a player that is not running, so the app
// never launches one.
import AppKit
import Foundation

@MainActor
final class Media: ObservableObject {
    static let shared = Media()

    struct State: Equatable {
        var available = false   // a player is running and has a track
        var spotify = false     // and it is Spotify
        var playing = false
        var title = "", artist = ""
    }
    enum Command { case previous, toggle, next }

    @Published private(set) var state = State()
    private var task: Task<Void, Never>?
    private let queue = DispatchQueue(label: "briareus.media")

    private static let players = [("com.spotify.client", "Spotify"), ("com.apple.Music", "Music")]

    /// Reads every second while the app is in the foreground, every five otherwise.
    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                await self?.read()
                let seconds: UInt64 = Store.shared.active ? 1 : 5
                try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
            }
        }
    }
    func stop() { task?.cancel(); task = nil }

    private func runningPlayer() -> (id: String, name: String)? {
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        return Media.players.first { running.contains($0.0) }.map { ($0.0, $0.1) }
    }

    private func read() async {
        guard let player = runningPlayer() else { if state != State() { state = State() }; return }
        let script = """
        tell application "\(player.name)"
            if player state is stopped then return ""
            set s to (player state as string)
            return s & (ASCII character 31) & (name of current track) & (ASCII character 31) & (artist of current track)
        end tell
        """
        let result: String? = await withCheckedContinuation { cont in
            queue.async {
                var error: NSDictionary?
                let out = NSAppleScript(source: script)?.executeAndReturnError(&error).stringValue
                cont.resume(returning: error == nil ? out : nil)
            }
        }
        var next = State()
        if let result, !result.isEmpty {
            let parts = result.components(separatedBy: "\u{1F}")
            next.available = true
            next.spotify = player.id == "com.spotify.client"
            next.playing = parts.first == "playing"
            next.title = parts.count > 1 ? parts[1] : ""
            next.artist = parts.count > 2 ? parts[2] : ""
        }
        if next != state { state = next }
    }

    /// Sends ⏮, ⏯ or ⏭ to the player shown; the state follows once the player has acted.
    func send(_ command: Command) {
        guard let player = runningPlayer() else { return }
        let verb = command == .previous ? "previous track" : command == .next ? "next track" : "playpause"
        queue.async {
            var error: NSDictionary?
            NSAppleScript(source: "tell application \"\(player.name)\" to \(verb)")?.executeAndReturnError(&error)
            Task { @MainActor in await Media.shared.read() }
        }
    }
}
