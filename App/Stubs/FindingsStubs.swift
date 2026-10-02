// Placeholders until the findings and usage screens are ported. Delete this file once they are.
import SwiftUI

struct FindingsScreen: View { let repo: String?; var body: some View { Text("Findings") } }
struct DashboardScreen: View { var body: some View { Text("Usage") } }
/// A review round waiting for verdicts, as a card: one verdict per finding, a note for the fix session and the button that
/// completes the triage. `done` runs once the server took it.
struct TriageCard: View { let session: Session; var done: () -> Void = {}; var body: some View { Text("Findings") } }
