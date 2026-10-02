// Placeholders until the conversations screens are ported. Delete this file once they are.
import SwiftUI

struct ProjectsList: View { var body: some View { Text("Projects") } }
struct ProjectView: View { let repo: String; var body: some View { Text(repo) } }
struct ConversationScreen: View { let sessionID: String; let initial: JSON?; var body: some View { Text(sessionID) } }
