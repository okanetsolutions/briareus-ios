// Briareus as ssh's SSH_ASKPASS (the Windows client's sftp_askpass_main). The SFTP sessions run sftp without a terminal,
// pointing ssh at this app's own executable for its prompts, with BRIAREUS_ASKPASS=1 in the environment: ssh runs it with
// the prompt as its one argument, and SSH_ASKPASS_PROMPT saying what kind of answer it wants. The app then asks in a window
// of its own, prints the answer for ssh and exits, before the app proper starts.
import AppKit
import Foundation

@MainActor
enum Askpass {
    /// When the environment says so, asks the prompt on the command line, prints the answer and exits with ssh's code;
    /// otherwise returns at once and the app starts as usual.
    static func runIfRequested() {
        let env = ProcessInfo.processInfo.environment
        guard env["BRIAREUS_ASKPASS"] == "1" else { return }
        let args = CommandLine.arguments
        let prompt = (args.count > 1 ? args[1] : "Password:").trimmingCharacters(in: .whitespacesAndNewlines)
        let kind = SSHAskpass.classify(prompt: prompt, kind: env["SSH_ASKPASS_PROMPT"])

        // Asked from the background (ssh started this process): no Dock icon, and the window comes forward and stays on top.
        let app = NSApplication.shared
        // Nothing of the app proper runs: not its delegate's launch, not its windows.
        app.delegate = nil
        app.setActivationPolicy(.accessory)
        app.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = SSHAskpass.title(kind)
        alert.informativeText = prompt
        var reply: (output: String, exitCode: Int32)
        switch kind {
        case .notice:
            // A notice, such as "touch your security key": shown, nothing read back.
            alert.alertStyle = .informational
            alert.addButton(withTitle: "OK")
            run(alert)
            reply = SSHAskpass.reply(.notice)
        case .hostKey, .confirm:
            // A host key never seen before (or a key that asks to be confirmed): No is the default, as on Windows.
            alert.alertStyle = .warning
            let yes = alert.addButton(withTitle: "Yes")
            let no = alert.addButton(withTitle: "No")
            yes.keyEquivalent = ""
            no.keyEquivalent = "\r"
            let accepted = run(alert) == .alertFirstButtonReturn
            reply = SSHAskpass.reply(kind, accepted: accepted)
        case .secret:
            alert.messageText = "SSH"
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: "Cancel")
            let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
            alert.accessoryView = field
            alert.window.initialFirstResponder = field
            let ok = run(alert) == .alertFirstButtonReturn
            reply = SSHAskpass.reply(.secret, secret: ok ? field.stringValue : nil)
            field.stringValue = ""
        }
        if !reply.output.isEmpty { FileHandle.standardOutput.write(Data(reply.output.utf8)) }
        reply.output = ""
        exit(reply.exitCode)
    }

    @discardableResult private static func run(_ alert: NSAlert) -> NSApplication.ModalResponse {
        alert.window.level = .floating
        NSApplication.shared.activate(ignoringOtherApps: true)
        return alert.runModal()
    }
}
