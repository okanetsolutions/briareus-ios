import SwiftUI

/// A review round held for verdicts. Completing it records every verdict on the pull
/// request; what is marked fix starts a paid fix session. An unmarked finding goes as
/// optional, as on the dashboard. On a review of somebody else's pull request the
/// findings are its author's, so completing only clears the card.
struct FindingsTriageCard: View {
    let triage: JSONValue
    let disabled: Bool
    let complete: (_ verdicts: [JSONValue], _ note: String) -> Void
    @State private var decisions: [String: String] = [:]
    @State private var note = ""
    @State private var confirming = false
    static let options = [(id: "fix", title: "Fix"), (id: "optional", title: "Optional"), (id: "dismissed", title: "Dismiss")]
    private var findings: [JSONValue] { triage["findings"].array }
    /// A standalone review says whose pull request it is; a loop round is always the user's.
    private var takesVerdicts: Bool { triage["mine"].bool ?? true }
    private var fixCount: Int { findings.filter { decision($0) == "fix" }.count }
    private func decision(_ finding: JSONValue) -> String {
        guard let key = finding["key"].string else { return "" }
        return decisions[key] ?? triage["drafts"]["verdicts"][key]["decision"].string ?? ""
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: "flag.fill").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.warning)
            ForEach(Array(findings.enumerated()), id: \.offset) { _, finding in
                VStack(alignment: .leading, spacing: 6) {
                    Text(finding["title"].string ?? "Finding").font(.subheadline)
                    Text([finding["severity"].string, finding["file"].string].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption.monospaced()).foregroundStyle(.secondary)
                    if let why = finding["parkedWhy"].string { Text(why).font(.caption).foregroundStyle(.secondary) }
                    if let url = safeWebURL(finding["url"].string) { Link("Open on GitHub", destination: url).font(.caption) }
                    if takesVerdicts, let key = finding["key"].string {
                        Picker("Decision", selection: Binding(get: { decision(finding) }, set: { decisions[key] = $0 })) {
                            if decision(finding).isEmpty { Text("—").tag("") }
                            ForEach(Self.options, id: \.id) { Text($0.title).tag($0.id) }
                        }.pickerStyle(.segmented)
                    }
                }
                .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            if takesVerdicts {
                TextField("Note for the fix session (optional)", text: $note, axis: .vertical).lineLimit(1...4)
                    .textFieldStyle(.roundedBorder).font(.callout)
            }
            Button { confirming = true } label: {
                Text(takesVerdicts ? "Complete triage" : "Clear findings").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent).disabled(disabled)
            Text(footer).font(.caption).foregroundStyle(.secondary)
        }
        .padding(14)
        .background(Theme.elevated, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Theme.warning.opacity(0.4), lineWidth: 0.5))
        .confirmationDialog(confirmTitle, isPresented: $confirming, titleVisibility: .visible) {
            Button(takesVerdicts ? "Complete" : "Clear") { complete(verdicts, note.trimmingCharacters(in: .whitespacesAndNewlines)) }
        }
    }
    private var title: String {
        let pr = triage["prNumber"].double.map { " · PR #\(Int($0))" } ?? ""
        let round = triage["round"].double.map { "Round \(Int($0)) findings" } ?? "Review findings"
        return round + pr
    }
    private var footer: String {
        guard takesVerdicts else { return "This review is of somebody else’s pull request; its author fixes the findings." }
        return "Verdicts are recorded on the pull request. Unmarked findings go as optional."
    }
    private var confirmTitle: String {
        guard takesVerdicts else { return "Clear these findings?" }
        return fixCount == 0 ? "Complete triage without fixes?" : "Start a paid fix session for \(fixCount) finding\(fixCount == 1 ? "" : "s")?"
    }
    private var verdicts: [JSONValue] {
        guard takesVerdicts else { return [] }
        return findings.compactMap { finding in
            guard let key = finding["key"].string else { return nil }
            let chosen = decision(finding)
            var verdict: [String: JSONValue] = ["key": .string(key), "decision": .string(chosen.isEmpty ? "optional" : chosen)]
            if let reason = triage["drafts"]["verdicts"][key]["reason"].string, !reason.isEmpty { verdict["reason"] = .string(reason) }
            return .object(verdict)
        }
    }
}
