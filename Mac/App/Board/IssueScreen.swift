// Placeholder until this screen is ported from the Windows client.
import SwiftUI

struct IssueScreen: View {
    var repo: String
    var issue: JSON
    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(title: "Issue")
            EmptyNote(title: "Not yet ported.")
            Spacer()
        }
    }
}
